import CFIDO2
import Foundation
import KPasskeyContract
import PasskeyWire

/// A single operation thread waits here; the main actor never blocks on native calls.
public final class PasskeyInteraction: @unchecked Sendable {
  private let condition = NSCondition()
  private var response: Message?
  private var stopped = false
  public let gate: PublicationGate
  public let deadline: ContinuousClock.Instant
  private let emit: @Sendable (String, [String]) -> Void
  public init(gate: PublicationGate, deadline: ContinuousClock.Instant,
              emit: @escaping @Sendable (String, [String]) -> Void) {
    self.gate = gate; self.deadline = deadline; self.emit = emit
  }
  public func respond(_ message: Message) {
    condition.lock(); defer { condition.unlock() }
    response = message; condition.signal()
  }
  public func cancel() {
    condition.lock(); defer { condition.unlock() }
    stopped = true; condition.signal()
  }
  public func ask(_ stage: String, choices: [String] = []) throws -> Message {
    try gate.check()
    condition.lock(); defer { condition.unlock() }
    response = nil
    emit(stage, choices)
    while response == nil && !stopped {
      try gate.check()
      condition.wait(until: Date(timeIntervalSinceNow: 0.05))
    }
    try gate.check()
    guard !stopped, let response else { throw KerberosFailure(.cancelled) }
    self.response = nil
    return response
  }
  public func progress(_ stage: String) { emit(stage, []) }
  public func remaining() throws -> Int32 {
    try gate.check()
    return Int32(max(1, min(30_000, Int(ContinuousClock.now.duration(to: deadline) / .milliseconds(1)))))
  }
}

public func deviceStatus(_ code: Int32) -> Status {
  switch code {
  case FIDO_ERR_NO_CREDENTIALS: return .wrongKey
  case FIDO_ERR_PIN_INVALID: return .pinInvalid
  case FIDO_ERR_PIN_BLOCKED: return .pinBlocked
  case FIDO_ERR_PIN_AUTH_BLOCKED: return .pinAuthBlocked
  case FIDO_ERR_PIN_REQUIRED, FIDO_ERR_PIN_NOT_SET: return .pinRequired
  case FIDO_ERR_UV_BLOCKED: return .uvBlocked
  case FIDO_ERR_UNSUPPORTED_OPTION, FIDO_ERR_UV_INVALID: return .uvUnavailable
  case FIDO_ERR_ACTION_TIMEOUT, FIDO_ERR_USER_ACTION_TIMEOUT: return .deadlineExceeded
  case FIDO_ERR_KEEPALIVE_CANCEL: return .cancelled
  case FIDO_ERR_RX, FIDO_ERR_TX, FIDO_ERR_NOTFOUND: return .deviceRemoved
  default: return .deviceFailure
  }
}

private func fidoChecked(_ code: Int32) throws {
  if code != FIDO_OK { throw KerberosFailure(deviceStatus(code), code: code) }
}

/// Selection tokens index this operation's manifest; device paths never cross XPC.
public func getAssertion(_ challenge: Challenge, interaction: PasskeyInteraction) throws -> Assertion {
  fido_init(0)
  var manifest = fido_dev_info_new(16)
  guard let manifestPointer = manifest else { throw KerberosFailure(.deviceFailure) }
  defer { fido_dev_info_free(&manifest, 16) }
  var count = 0
  try fidoChecked(fido_dev_info_manifest(manifestPointer, 16, &count))
  try interaction.gate.check()
  guard count > 0 else { throw KerberosFailure(.keyAbsent) }
  let choices = (0..<count).map { index -> String in
    let info = fido_dev_info_ptr(manifestPointer, index)
    let label = fido_dev_info_product_string(info).map { String(cString: $0) } ?? "FIDO security key"
    let safe = label.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    return "\(index + 1): " + String(String.UnicodeScalarView(safe)).prefix(24)
  }
  let selected = count == 1 ? "device-0" : try interaction.ask("selectDevice", choices: choices).value
  guard let index = (0..<count).first(where: { selected == "device-\($0)" }),
    let path = fido_dev_info_path(fido_dev_info_ptr(manifestPointer, index))
  else { throw KerberosFailure(.protocolViolation) }
  var device = fido_dev_new()
  guard let dev = device else { throw KerberosFailure(.deviceFailure) }
  defer { fido_dev_free(&device) }
  try fidoChecked(fido_dev_set_timeout(dev, interaction.remaining()))
  try fidoChecked(fido_dev_open(dev, path))
  defer { fido_dev_close(dev) }
  guard fido_dev_is_fido2(dev) else { throw KerberosFailure(.uvUnavailable) }
  var assertion = fido_assert_new()
  guard let handle = assertion else { throw KerberosFailure(.deviceFailure) }
  defer { fido_assert_free(&assertion) }
  try fidoChecked(fido_assert_set_rp(handle, challenge.domain))
  let hash = try binary(challenge.cryptographic_challenge, maximum: 32)
  try fidoChecked(hash.withUnsafeBytes { fido_assert_set_clientdata_hash(handle, $0.baseAddress, $0.count) })
  for id in challenge.credential_id_list {
    let bytes = try binary(id, maximum: 1024)
    try fidoChecked(bytes.withUnsafeBytes { fido_assert_allow_cred(handle, $0.baseAddress, $0.count) })
  }
  try fidoChecked(fido_assert_set_up(handle, FIDO_OPT_TRUE))
  let uv = challenge.user_verification == 1
  let onboard = uv && fido_dev_has_uv(dev)
  guard !uv || onboard || fido_dev_has_pin(dev) else { throw KerberosFailure(.uvUnavailable) }
  // A supplied PIN provides UV; libfido2 requires the CTAP uv option omitted in that case.
  try fidoChecked(fido_assert_set_uv(handle, onboard ? FIDO_OPT_TRUE : FIDO_OPT_OMIT))
  func request(pin: Data?) throws -> Int32 {
    try fidoChecked(fido_dev_set_timeout(dev, interaction.remaining()))
    interaction.progress(onboard && pin == nil ? "verifyOnDevice" : "touchKey")
    var bytes = pin.map { Array($0) + [0] }
    defer { if bytes != nil { bytes!.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } } }
    let code = bytes?.withUnsafeBytes {
      fido_dev_get_assert(dev, handle, $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    } ?? fido_dev_get_assert(dev, handle, nil)
    try interaction.gate.check()
    return code
  }
  func pin() throws -> Data {
    let answer = try interaction.ask("pin")
    guard let pin = answer.secret, pin.count <= 63,
      let text = String(data: pin, encoding: .utf8), text.unicodeScalars.count >= 4
    else { throw KerberosFailure(.protocolViolation) }
    return pin
  }
  var code: Int32
  if uv && !onboard { code = try request(pin: pin()) }
  else {
    code = try request(pin: nil)
    // Only PIN_REQUIRED permits one PIN attempt, never an automatic wrong-PIN/UV retry.
    if code == FIDO_ERR_PIN_REQUIRED && fido_dev_has_pin(dev) {
      try fidoChecked(fido_assert_set_uv(handle, FIDO_OPT_OMIT))
      code = try request(pin: pin())
    }
  }
  try fidoChecked(code)
  func bytes(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> Data {
    guard let pointer, count > 0 else { return Data() }
    return Data(bytes: pointer, count: count)
  }
  // All entries must match the allow-list. The first valid entry is sufficient for this principal.
  guard (1...64).contains(fido_assert_count(handle)) else { throw KerberosFailure(.passkeyInvalid) }
  var result: Assertion?
  for i in 0..<fido_assert_count(handle) {
    let user = bytes(fido_assert_user_id_ptr(handle, i), fido_assert_user_id_len(handle, i))
    let item = Assertion(credential: bytes(fido_assert_id_ptr(handle, i), fido_assert_id_len(handle, i)),
      challenge: challenge.cryptographic_challenge,
      authdata: bytes(fido_assert_authdata_ptr(handle, i), fido_assert_authdata_len(handle, i)),
      signature: bytes(fido_assert_sig_ptr(handle, i), fido_assert_sig_len(handle, i)),
      user: user.isEmpty ? nil : user)
    try item.validate(challenge: challenge)
    if result == nil { result = item }
  }
  return result!
}
