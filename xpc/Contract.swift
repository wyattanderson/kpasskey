import Foundation

public let workerIdentifier = "org.kpasskey.harness.worker"
public let hostIdentifier = "org.kpasskey.harness"

public enum Status: String, Sendable {
  case ok, protocolViolation, unsupportedVersion, busy, staleInteraction
  case cancelled, deadlineExceeded, workerLost, disconnected, scriptedFailure
}

/// M2-only immutable configuration. Real Kerberos settings belong to M3.
@objc(KPasskeySnapshot)
public final class Snapshot: NSObject, NSSecureCoding, Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let schema: Int
  public let principal: String
  public let realm: String
  public let outcome: String
  public let timeoutMilliseconds: Int

  public init(
    schema: Int = 1, principal: String = "demo", realm: String = "EXAMPLE.INVALID",
    outcome: String = "success", timeoutMilliseconds: Int = 10_000
  ) {
    self.schema = schema
    self.principal = principal
    self.realm = realm
    self.outcome = outcome
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  public var valid: Bool {
    schema == 1 && !principal.isEmpty && !realm.isEmpty
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
    self.init(
      schema: coder.decodeInteger(forKey: "schema"), principal: principal, realm: realm,
      outcome: outcome, timeoutMilliseconds: coder.decodeInteger(forKey: "timeout"))
    guard valid else { return nil }
  }

  public func encode(with coder: NSCoder) {
    coder.encode(schema, forKey: "schema")
    coder.encode(principal as NSString, forKey: "principal")
    coder.encode(realm as NSString, forKey: "realm")
    coder.encode(outcome as NSString, forKey: "outcome")
    coder.encode(timeoutMilliseconds, forKey: "timeout")
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

  public init(
    _ kind: String, version: Int = 1, operation: String = "",
    interaction: String = "", value: String = "", sequence: Int = 0,
    snapshot: Snapshot? = nil, remainingMilliseconds: Int = 0
  ) {
    self.kind = kind
    self.version = version
    self.operation = operation
    self.interaction = interaction
    self.value = value
    self.sequence = sequence
    self.snapshot = snapshot
    self.remainingMilliseconds = remainingMilliseconds
  }

  public var bounded: Bool {
    kind.utf8.count <= 32 && operation.utf8.count <= 36 && interaction.utf8.count <= 36
      && value.utf8.count <= 256 && sequence >= 0 && (0...30_000).contains(remainingMilliseconds)
      && (snapshot?.valid ?? true)
  }

  public var validCommand: Bool {
    guard bounded, sequence == 0, remainingMilliseconds == 0 else { return false }
    switch kind {
    case "negotiate":
      return operation.isEmpty && interaction.isEmpty && value.isEmpty && snapshot == nil
    case "start":
      return UUID(uuidString: operation)?.uuidString == operation && interaction.isEmpty
        && value.isEmpty
        && snapshot != nil
    case "respond":
      return UUID(uuidString: operation)?.uuidString == operation
        && UUID(uuidString: interaction)?.uuidString == interaction
        && ["key-1", "continue"].contains(value) && snapshot == nil
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
    self.init(
      kind, version: coder.decodeInteger(forKey: "version"), operation: operation,
      interaction: interaction, value: value, sequence: coder.decodeInteger(forKey: "sequence"),
      snapshot: coder.decodeObject(of: Snapshot.self, forKey: "snapshot"),
      remainingMilliseconds: coder.decodeInteger(forKey: "remainingMilliseconds"))
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
  let classes = NSSet(array: [Message.self, Snapshot.self, NSString.self]) as! Set<AnyHashable>
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
    NSSet(array: [Message.self, NSString.self]) as! Set<AnyHashable>,
    for: #selector(ClientProtocol.receive(_:)), argumentIndex: 0, ofReply: false)
  return interface
}
