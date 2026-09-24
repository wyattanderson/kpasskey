import CMITKerberos
import Foundation
import KPasskeyContract
import PasskeyWire

public struct PasskeyPlugins: Sendable {
  public let passkey: String
  public let pkinit: String

  public init(passkey: String, pkinit: String) {
    self.passkey = passkey
    self.pkinit = pkinit
  }

  public static func bundled() -> PasskeyPlugins {
    let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns")
    return PasskeyPlugins(passkey: directory.appendingPathComponent("kpasskey.dylib").path,
                          pkinit: directory.appendingPathComponent("pkinit.so").path)
  }
}

private final class Responder {
  let interaction: PasskeyInteraction
  var failure: Error?
  var answered = false

  init(_ interaction: PasskeyInteraction) { self.interaction = interaction }
}

/// Armor, trust-file and all MIT allocations are confined to this synchronous operation.
public func acquirePasskey(_ settings: Configuration, interaction: PasskeyInteraction,
                           plugins: PasskeyPlugins = .bundled()) throws -> TicketMetadata {
  guard settings.valid, settings.mode == .passkey, settings.validPKINITCA
  else { throw KerberosFailure(.configurationInvalid) }
  try interaction.gate.check()
  let manager = FileManager.default
  let directory = manager.temporaryDirectory.appendingPathComponent("KPasskey-" + UUID().uuidString)
  try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                              attributes: [.posixPermissions: 0o700])
  defer { try? manager.removeItem(at: directory) }

  let anchors = directory.appendingPathComponent("ca.pem")
  let pem = "-----BEGIN CERTIFICATE-----\n" + settings.pkinitCA.base64EncodedString(options: .lineLength64Characters)
    + "\n-----END CERTIFICATE-----\n"
  try Data(pem.utf8).write(to: anchors)
  let armorContext = try makeContext(settings, plugin: plugins.pkinit, armor: true, anchors: anchors.path)
  defer { krb5_free_context(armorContext) }
  var armor: krb5_ccache?
  try checked(krb5_cc_new_unique(armorContext, "MEMORY", nil, &armor), .armorFailed)
  guard let armor else { throw KerberosFailure(.armorFailed) }
  defer { krb5_cc_destroy(armorContext, armor) }
  var anonymous: krb5_principal?
  try checked(krb5_parse_name(armorContext, "WELLKNOWN/ANONYMOUS@" + settings.effectiveRealm, &anonymous), .armorFailed)
  guard let anonymous else { throw KerberosFailure(.armorFailed) }
  defer { krb5_free_principal(armorContext, anonymous) }
  let armorOptions = try credentialOptions(settings, context: armorContext)
  defer { krb5_get_init_creds_opt_free(armorContext, armorOptions) }
  krb5_get_init_creds_opt_set_anonymous(armorOptions, 1)
  krb5_get_init_creds_opt_set_forwardable(armorOptions, 0)
  krb5_get_init_creds_opt_set_renew_life(armorOptions, 0)
  try checked(krb5_get_init_creds_opt_set_out_ccache(armorContext, armorOptions, armor), .armorFailed)
  var armorCredentials = krb5_creds()
  defer { krb5_free_cred_contents(armorContext, &armorCredentials) }
  interaction.progress("acquiringArmor")
  let armorCode = krb5_get_init_creds_password(armorContext, &armorCredentials, anonymous, nil,
    { _, _, _, _, _, _ in Int32(KRB5_LIBOS_CANTREADPWD) }, nil, 0, nil, armorOptions)
  try interaction.gate.check()
  try checked(armorCode, .armorFailed)
  guard armorCredentials.ticket_flags & TKT_FLG_ANONYMOUS != 0 else { throw KerberosFailure(.armorFailed) }

  let context = try makeContext(settings, plugin: plugins.passkey)
  defer { krb5_free_context(context) }
  let principal = try resolvePrincipal(settings, context: context)
  defer { krb5_free_principal(context, principal) }
  let options = try credentialOptions(settings, context: context)
  defer { krb5_get_init_creds_opt_free(context, options) }
  try checked(krb5_get_init_creds_opt_set_fast_ccache(context, options, armor), .armorFailed)
  try checked(krb5_get_init_creds_opt_set_fast_flags(context, options, KRB5_FAST_REQUIRED), .armorFailed)
  var staging: krb5_ccache?
  try checked(krb5_cc_new_unique(context, "MEMORY", nil, &staging))
  guard let staging else { throw KerberosFailure(.configurationInvalid) }
  defer { krb5_cc_destroy(context, staging) }
  try checked(krb5_get_init_creds_opt_set_out_ccache(context, options, staging))

  let responder = Responder(interaction)
  try checked(krb5_get_init_creds_opt_set_responder(context, options, { context, pointer, rctx in
    guard let pointer, let context, let rctx else { return Int32(KRB5_PREAUTH_FAILED) }
    let state = Unmanaged<Responder>.fromOpaque(pointer).takeUnretainedValue()
    do {
      try state.interaction.gate.check()
      guard let question = krb5_responder_get_challenge(context, rctx, passkeyQuestion) else {
        // Initial callbacks can be empty. Any actual other mechanism's question is rejected.
        if krb5_responder_list_questions(context, rctx)?.pointee != nil {
          throw KerberosFailure(.passkeyRequired)
        }
        return 0
      }
      guard !state.answered else { throw KerberosFailure(.passkeyInvalid) }
      let message = try decodeWire(responderBytes(question), as: Challenge.self, phase: 1)
      try message.data.validate()
      let assertion = try getAssertion(message.data, interaction: state.interaction)
      let reply = try encodeWire(Envelope(phase: 2, state: message.state, data: assertion))
      try state.interaction.gate.check()
      let code = reply.withUnsafeBytes { buffer -> Int32 in
        guard let baseAddress = buffer.baseAddress else { return Int32(KRB5_PREAUTH_FAILED) }
        return krb5_responder_set_answer(
          context, rctx, passkeyQuestion, baseAddress.assumingMemoryBound(to: CChar.self))
      }
      if code == 0 { state.answered = true }
      return code
    } catch {
      state.failure = (error as? KerberosFailure) ?? KerberosFailure(.passkeyInvalid)
      return Int32(KRB5_PREAUTH_FAILED)
    }
  }, Unmanaged.passUnretained(responder).toOpaque()))
  var credentials = krb5_creds()
  defer { krb5_free_cred_contents(context, &credentials) }
  interaction.progress("authenticating")
  let code = withExtendedLifetime(responder) {
    krb5_get_init_creds_password(context, &credentials, principal, nil,
      { _, _, _, _, _, _ in Int32(KRB5_LIBOS_CANTREADPWD) }, nil, 0, nil, options)
  }
  try interaction.gate.check()
  if let failure = responder.failure { throw failure }
  try checked(code, authenticationStatus(code))
  var marker = krb5_data()
  defer { krb5_free_data_contents(context, &marker) }
  guard responder.answered,
    krb5_cc_get_config(context, staging, credentials.server, "pa_type", &marker) == 0,
    let data = marker.data, Data(bytes: data, count: Int(marker.length)) == Data("153".utf8)
  else { throw KerberosFailure(.passkeyRequired) }
  return try publish(context: context, staging: staging, credentials: &credentials,
    makeDefault: settings.makeDefault, gate: interaction.gate, mode: "passkey")
}
