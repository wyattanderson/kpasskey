import CFIDO2
import CMITKerberos
import Foundation
import KPasskeyContract
import KPasskeyWorker
import PasskeyWire
import Testing

@Test func certificateSubjectMustMatchRealmBeforeAnyPasskeyInteraction() throws {
  var settings = Configuration(principal: "user@EXAMPLE.ORG")
  settings.mode = .passkey
  let path = try #require(ProcessInfo.processInfo.environment["KPASSKEY_TEST_CA"])
  settings.pkinitCA = try Data(contentsOf: URL(fileURLWithPath: path))
  #expect(settings.validPKINITCA)
  #expect(try Configuration.load(PropertyListEncoder().encode(settings)).validPKINITCA)
  var legacy = try #require(PropertyListSerialization.propertyList(
    from: PropertyListEncoder().encode(settings), format: nil) as? [String: Any])
  #expect(legacy["rpID"] == nil)
  legacy["rpID"] = "override.invalid"
  let migrated = try Configuration.load(PropertyListSerialization.data(
    fromPropertyList: legacy, format: .binary, options: 0))
  #expect(migrated.principal == settings.principal && migrated.pkinitCA == settings.pkinitCA)
  let saved = try #require(PropertyListSerialization.propertyList(
    from: PropertyListEncoder().encode(migrated), format: nil) as? [String: Any])
  #expect(saved["rpID"] == nil)
  for realm in ["OTHER.ORG", "EXAMPLE", "EXAMPLE.ORG.EVIL", "example.org", ""] {
    settings.principal = "user"
    settings.realm = realm
    #expect(!settings.validPKINITCA)
    let bridge = PasskeyInteraction(gate: PublicationGate(), deadline: .now.advanced(by: .seconds(1))) { _, _ in
      Issue.record("Mismatched trust must be rejected before interaction")
    }
    do {
      _ = try acquirePasskey(settings, interaction: bridge)
      Issue.record("Mismatched trust was accepted")
    } catch let error as KerberosFailure { #expect(error.status == .configurationInvalid) }
  }
}

@Test func passkeyConfigurationAndModuleIsolation() throws {
  var settings = Configuration(principal: "user@EXAMPLE.ORG")
  settings.mode = .passkey
  #expect(!settings.valid)
  settings.pkinitCA = Data([1])
  #expect(settings.valid) // Certificate syntax is checked separately before PKINIT.
  for armor in [true, false] {
    let profile = try makeProfile(settings, plugin: "/bundle with spaces/plugin.dylib",
                                  armor: armor, anchors: "/private/ca.pem")
    defer { profile_abandon(profile) }
    var value: UnsafeMutablePointer<CChar>?
    #expect(profile_get_string(profile, "plugins", "clpreauth", "enable_only", nil, &value) == 0)
    #expect(value.map { String(cString: $0) } == (armor ? "pkinit" : "kpasskey"))
    profile_release_string(value)
    value = nil
    #expect(profile_get_string(profile, "kpasskey", "rp", nil, nil, &value) == 0)
    #expect(value == nil)
    profile_release_string(value)
  }
  #expect(throws: KerberosFailure.self) { try makeContext(settings) }
  #expect(throws: KerberosFailure.self) {
    try acquirePassword(settings, password: Data([1]), gate: PublicationGate())
  }
  let bridge = PasskeyInteraction(gate: PublicationGate(), deadline: .now.advanced(by: .seconds(1))) { _, _ in }
  do {
    _ = try acquirePasskey(settings, interaction: bridge)
    Issue.record("Malformed trust must be rejected before network/device/cache access")
  } catch let error as KerberosFailure { #expect(error.status == .configurationInvalid) }
  settings.canonicalize = true
  #expect(!settings.valid)
}

@Test func deviceErrorsKeepSafeRetryDistinctions() {
  #expect(authenticationStatus(WireError.rpInvalid.rawValue) == .passkeyInvalid)
  for (code, status): (Int32, Status) in [
    (FIDO_ERR_NO_CREDENTIALS, .wrongKey), (FIDO_ERR_PIN_INVALID, .pinInvalid),
    (FIDO_ERR_PIN_BLOCKED, .pinBlocked), (FIDO_ERR_PIN_AUTH_BLOCKED, .pinAuthBlocked),
    (FIDO_ERR_PIN_REQUIRED, .pinRequired), (FIDO_ERR_PIN_NOT_SET, .pinRequired),
    (FIDO_ERR_UV_BLOCKED, .uvBlocked), (FIDO_ERR_UV_INVALID, .uvUnavailable),
    (FIDO_ERR_RX, .deviceRemoved), (FIDO_ERR_TX, .deviceRemoved),
    (FIDO_ERR_ACTION_TIMEOUT, .deadlineExceeded), (FIDO_ERR_KEEPALIVE_CANCEL, .cancelled),
  ] { #expect(deviceStatus(code) == status) }
}

@Test func nativeInteractionCancellationAndDeadlineNeverCommit() async throws {
  for cancel in [false, true] {
    let gate = PublicationGate(deadline: .now.advanced(by: .milliseconds(100)))
    let bridge = PasskeyInteraction(gate: gate, deadline: .now.advanced(by: .milliseconds(100))) { _, _ in }
    let waiting = Task.detached { Result { try bridge.ask("pin") } }
    if cancel { gate.cancel(); bridge.cancel() }
    switch await waiting.value {
    case .success: Issue.record("Unanswered interaction succeeded")
    case .failure(let failure):
      #expect((failure as? KerberosFailure)?.status == (cancel ? .cancelled : .deadlineExceeded))
    }
    #expect(throws: KerberosFailure.self) { try gate.beginPublication() }
  }
}

@Test func passkeyInteractionArchivesAreBounded() throws {
  let message = Message("interaction", operation: UUID().uuidString,
    interaction: UUID().uuidString, value: "selectDevice", choices: ["1: key", "2: another key"])
  let bytes = try NSKeyedArchiver.archivedData(withRootObject: message, requiringSecureCoding: true)
  let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: bytes))
  #expect(decoded.choices == message.choices)
  #expect(!Message("interaction", choices: Array(repeating: "key", count: 17)).bounded)
  #expect(!Message("interaction", choices: ["key\nspoofed output"]).bounded)
  #expect(Message("respond", operation: message.operation, interaction: message.interaction, value: "device-1").validCommand)
  #expect(!Message("respond", operation: message.operation, interaction: message.interaction, value: "device-16").validCommand)
}
