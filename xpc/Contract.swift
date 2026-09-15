import Foundation

public let workerIdentifier = "org.kpasskey.harness.worker"
public let hostIdentifier = "org.kpasskey.harness"
public let applicationIdentifier = "org.kpasskey.KPasskey"
public let applicationWorkerIdentifier = "org.kpasskey.KPasskey.worker"

public enum Status: String, Sendable {
  case ok, protocolViolation, unsupportedVersion, busy, staleInteraction
  case cancelled, deadlineExceeded, workerLost, disconnected, scriptedFailure
  case configurationInvalid, kdcUnavailable, credentialsRejected, unexpectedPrompt
  case authenticationFailed, publicationFailed
  case passkeyInvalid, armorFailed, passkeyRequired, keyAbsent, wrongKey, deviceRemoved
  case pinInvalid, pinBlocked, pinAuthBlocked, pinRequired, uvUnavailable, uvBlocked, deviceFailure
}

private func encodePropertyList<T: Encodable>(_ value: T, forKey key: String, with coder: NSCoder) {
  do {
    coder.encode(try PropertyListEncoder().encode(value) as NSData, forKey: key)
  } catch {
    coder.failWithError(error)
  }
}

/// Immutable per-operation snapshot; configuration selects real authentication.
@objc(KPasskeySnapshot)
public final class Snapshot: NSObject, NSSecureCoding, Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let schema: Int
  public let principal: String
  public let realm: String
  public let outcome: String
  public let timeoutMilliseconds: Int
  public let configuration: Configuration?
  public let selectedDevice: String

  public init(
    schema: Int = 1, principal: String = "demo", realm: String = "EXAMPLE.INVALID",
    outcome: String = "success", timeoutMilliseconds: Int = 10_000,
    configuration: Configuration? = nil, selectedDevice: String = ""
  ) {
    self.schema = schema
    self.principal = principal
    self.realm = realm
    self.outcome = outcome
    self.timeoutMilliseconds = configuration?.timeoutMilliseconds ?? timeoutMilliseconds
    self.configuration = configuration
    self.selectedDevice = selectedDevice
  }

  public var valid: Bool {
    schema == 1 && (configuration?.valid ?? true) && !principal.isEmpty && !realm.isEmpty
      && (selectedDevice.isEmpty || (configuration?.mode == .passkey
        && UUID(uuidString: selectedDevice)?.uuidString == selectedDevice))
      && principal.utf8.count <= 256 && realm.utf8.count <= 256
      && ["success", "failure"].contains(outcome)
      && (200...30_000).contains(timeoutMilliseconds)
      && !principal.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      && !realm.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  public required convenience init?(coder: NSCoder) {
    guard let principal = coder.decodeObject(of: NSString.self, forKey: "principal") as String?,
      let realm = coder.decodeObject(of: NSString.self, forKey: "realm") as String?,
      let outcome = coder.decodeObject(of: NSString.self, forKey: "outcome") as String?
    else { return nil }
    var configuration: Configuration?
    if coder.containsValue(forKey: "configuration") {
      guard let bytes = coder.decodeObject(of: NSData.self, forKey: "configuration") as Data?,
        bytes.count <= 8192,
        let decoded = try? PropertyListDecoder().decode(Configuration.self, from: bytes), decoded.valid
      else { return nil }
      configuration = decoded
    }
    self.init(
      schema: coder.decodeInteger(forKey: "schema"), principal: principal, realm: realm,
      outcome: outcome, timeoutMilliseconds: coder.decodeInteger(forKey: "timeout"),
      configuration: configuration,
      selectedDevice: coder.decodeObject(of: NSString.self, forKey: "selectedDevice") as String? ?? "")
    guard valid else { return nil }
  }

  public func encode(with coder: NSCoder) {
    coder.encode(schema, forKey: "schema")
    coder.encode(selectedDevice as NSString, forKey: "selectedDevice")
    coder.encode(principal as NSString, forKey: "principal")
    coder.encode(realm as NSString, forKey: "realm")
    coder.encode(outcome as NSString, forKey: "outcome")
    coder.encode(timeoutMilliseconds, forKey: "timeout")
    if let configuration {
      encodePropertyList(configuration, forKey: "configuration", with: coder)
    }
  }
}

/// One bounded envelope, with a strict per-command shape checked by the receiver.
@objc(KPasskeyMessage)
public final class Message: NSObject, NSSecureCoding, Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let kind: String
  public let version: Int
  public let operation: String
  public let interaction: String
  public let value: String
  public let sequence: Int
  public let remainingMilliseconds: Int
  public let snapshot: Snapshot?
  public let secret: Data?
  public let ticket: TicketMetadata?
  public let errorCode: Int32
  public let choices: [String]
  public let devices: [SecurityKey]

  public init(
    _ kind: String, version: Int = 4, operation: String = "",
    interaction: String = "", value: String = "", sequence: Int = 0,
    snapshot: Snapshot? = nil, remainingMilliseconds: Int = 0,
    secret: Data? = nil, ticket: TicketMetadata? = nil, errorCode: Int32 = 0,
    choices: [String] = [], devices: [SecurityKey] = []
  ) {
    self.kind = kind
    self.version = version
    self.operation = operation
    self.interaction = interaction
    self.value = value
    self.sequence = sequence
    self.snapshot = snapshot
    self.remainingMilliseconds = remainingMilliseconds
    self.secret = secret
    self.ticket = ticket
    self.errorCode = errorCode
    self.choices = choices
    self.devices = devices
  }

  public var bounded: Bool {
    kind.utf8.count <= 32 && operation.utf8.count <= 36 && interaction.utf8.count <= 36
      && value.utf8.count <= 256 && sequence >= 0 && (0...30_000).contains(remainingMilliseconds)
      && (snapshot?.valid ?? true)
      && (secret.map { !$0.isEmpty && $0.count <= 4096 && !$0.contains(0) } ?? true)
      && (ticket?.valid ?? true)
      && devices.count <= 16 && devices.allSatisfy(\.valid)
      && Set(devices.map(\.id)).count == devices.count
      && choices.count <= 16 && choices.allSatisfy {
        !$0.isEmpty && $0.utf8.count <= 128
          && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
      }
  }

  public var validCommand: Bool {
    guard bounded, devices.isEmpty, choices.isEmpty, sequence == 0, remainingMilliseconds == 0, ticket == nil, errorCode == 0,
      secret == nil || kind == "respond" else { return false }
    switch kind {
    case "negotiate", "devices":
      return operation.isEmpty && interaction.isEmpty && value.isEmpty && snapshot == nil
    case "start":
      return UUID(uuidString: operation)?.uuidString == operation && interaction.isEmpty
        && value.isEmpty
        && snapshot != nil
    case "respond":
      return UUID(uuidString: operation)?.uuidString == operation
        && UUID(uuidString: interaction)?.uuidString == interaction
        && ((secret == nil && (["key-1", "continue"].contains(value)
          || (0..<16).contains(where: { value == "device-\($0)" })))
          || (secret != nil && value.isEmpty)) && snapshot == nil
    case "cancel":
      return UUID(uuidString: operation)?.uuidString == operation && interaction.isEmpty
        && value.isEmpty
        && snapshot == nil
    default: return false
    }
  }

  public required convenience init?(coder: NSCoder) {
    guard let kind = coder.decodeObject(of: NSString.self, forKey: "kind") as String?,
      let operation = coder.decodeObject(of: NSString.self, forKey: "operation") as String?,
      let interaction = coder.decodeObject(of: NSString.self, forKey: "interaction") as String?,
      let value = coder.decodeObject(of: NSString.self, forKey: "value") as String?
    else { return nil }
    var ticket: TicketMetadata?
    var devices: [SecurityKey] = []
    if coder.containsValue(forKey: "devices") {
      guard let bytes = coder.decodeObject(of: NSData.self, forKey: "devices") as Data?,
        bytes.count <= 8192,
        let decoded = try? PropertyListDecoder().decode([SecurityKey].self, from: bytes)
      else { return nil }
      devices = decoded
    }
    if coder.containsValue(forKey: "ticket") {
      guard let bytes = coder.decodeObject(of: NSData.self, forKey: "ticket") as Data?,
        bytes.count <= 4096,
        let decoded = try? PropertyListDecoder().decode(TicketMetadata.self, from: bytes), decoded.valid
      else { return nil }
      ticket = decoded
    }
    self.init(
      kind, version: coder.decodeInteger(forKey: "version"), operation: operation,
      interaction: interaction, value: value, sequence: coder.decodeInteger(forKey: "sequence"),
      snapshot: coder.decodeObject(of: Snapshot.self, forKey: "snapshot"),
      remainingMilliseconds: coder.decodeInteger(forKey: "remainingMilliseconds"),
      secret: coder.decodeObject(of: NSData.self, forKey: "secret") as Data?, ticket: ticket,
      errorCode: coder.decodeInt32(forKey: "errorCode"),
      choices: coder.decodeObject(of: [NSArray.self, NSString.self], forKey: "choices") as? [String] ?? [],
      devices: devices)
    guard bounded else { return nil }
  }

  public func encode(with coder: NSCoder) {
    coder.encode(kind as NSString, forKey: "kind")
    coder.encode(version, forKey: "version")
    coder.encode(operation as NSString, forKey: "operation")
    coder.encode(interaction as NSString, forKey: "interaction")
    coder.encode(value as NSString, forKey: "value")
    coder.encode(sequence, forKey: "sequence")
    coder.encode(snapshot, forKey: "snapshot")
    coder.encode(remainingMilliseconds, forKey: "remainingMilliseconds")
    coder.encode(secret as NSData?, forKey: "secret")
    coder.encode(errorCode, forKey: "errorCode")
    coder.encode(choices as NSArray, forKey: "choices")
    if !devices.isEmpty { encodePropertyList(devices, forKey: "devices", with: coder) }
    if let ticket { encodePropertyList(ticket, forKey: "ticket", with: coder) }
  }
}

@objc public protocol WorkerProtocol {
  func exchange(_ message: Message, reply: @escaping @Sendable (Message) -> Void)
}

@objc public protocol ClientProtocol {
  func receive(_ event: Message)
}

public func workerInterface() -> NSXPCInterface {
  let interface = NSXPCInterface(with: WorkerProtocol.self)
  let classes = NSSet(array: [Message.self, Snapshot.self, NSString.self, NSData.self, NSArray.self]) as! Set<AnyHashable>
  for reply in [false, true] {
    interface.setClasses(
      classes, for: #selector(WorkerProtocol.exchange(_:reply:)),
      argumentIndex: 0, ofReply: reply)
  }
  return interface
}

public func clientInterface() -> NSXPCInterface {
  let interface = NSXPCInterface(with: ClientProtocol.self)
  interface.setClasses(
    NSSet(array: [Message.self, NSString.self, NSData.self, NSArray.self]) as! Set<AnyHashable>,
    for: #selector(ClientProtocol.receive(_:)), argumentIndex: 0, ofReply: false)
  return interface
}
