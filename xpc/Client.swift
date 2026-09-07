import Foundation
import KPasskeyContract

public struct ClientFailure: Error, Sendable { public let status: Status }

private final class EventSink: NSObject, ClientProtocol, Sendable {
  let deliver: @Sendable (Message) -> Void
  init(deliver: @escaping @Sendable (Message) -> Void) { self.deliver = deliver }
  func receive(_ event: Message) { deliver(event) }
}

/// The UI and console use this same main-actor adapter. Nothing reconnects or retries implicitly.
@MainActor
public final class WorkerClient {
  public var onEvent: @MainActor (Message) -> Void = { _ in }
  public private(set) var workerPID: Int32 = 0
  private var connection: NSXPCConnection?
  private var generation = UUID()
  private var ready = false
  private var pending: [UUID: CheckedContinuation<Message, any Error>] = [:]
  private var operations: [String: Int] = [:]
  private var deadlines: [String: Task<Void, Never>] = [:]

  public init() {}

  public func connect() async throws {
    disconnect()
    let token = UUID()
    generation = token
    let connection = NSXPCConnection(serviceName: workerIdentifier)
    let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/Worker.xpc")
    connection.setCodeSigningRequirement(
      try PeerPolicy.requirement(peer: service, identifier: workerIdentifier))
    connection.remoteObjectInterface = workerInterface()
    connection.exportedInterface = clientInterface()
    connection.exportedObject = EventSink { [weak self] event in
      Task { @MainActor in
        guard let self, self.generation == token else { return }
        self.receive(event)
      }
    }
    let lost: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in
        guard let self, self.generation == token else { return }
        self.close(.workerLost)
      }
    }
    connection.interruptionHandler = lost
    connection.invalidationHandler = lost
    self.connection = connection
    connection.activate()
    // launchd throttles a service restart after a crash; negotiation allows that delay.
    let reply = try await exchange(Message("negotiate"), timeout: .seconds(15))
    guard generation == token else { throw ClientFailure(status: .disconnected) }
    guard reply.kind == "negotiated", reply.version == 1, reply.value == "fake",
      reply.sequence > 0, reply.sequence <= Int(Int32.max), reply.sequence != Int(getpid())
    else {
      close(.protocolViolation)
      throw ClientFailure(status: .protocolViolation)
    }
    workerPID = Int32(reply.sequence)
    ready = true
  }

  @discardableResult
  public func start(_ snapshot: Snapshot, operation: String = UUID().uuidString) async throws
    -> Message
  {
    guard ready, UUID(uuidString: operation)?.uuidString == operation, snapshot.valid else {
      throw ClientFailure(status: .protocolViolation)
    }
    let tracking = operations[operation] == nil
    let token = generation
    if tracking {
      operations[operation] = 0
      armDeadline(operation, milliseconds: snapshot.timeoutMilliseconds + 1_000)
    }
    do {
      let reply = try await exchange(Message("start", operation: operation, snapshot: snapshot))
      if generation == token && reply.value != Status.ok.rawValue && tracking { forget(operation) }
      return reply
    } catch {
      if generation == token && tracking { forget(operation) }
      throw error
    }
  }

  public func respond(to event: Message, value: String) async throws -> Message {
    try await exchange(
      Message(
        "respond", operation: event.operation,
        interaction: event.interaction, value: value))
  }

  public func cancel(_ operation: String) async throws -> Message {
    if operations[operation] != nil { armDeadline(operation, milliseconds: 1_000) }
    return try await exchange(Message("cancel", operation: operation))
  }

  /// Also used by the harness's malformed-wire checks. Normal callers use the typed methods above.
  public func exchange(_ message: Message, timeout: Duration = .seconds(5)) async throws -> Message
  {
    guard let connection else { throw ClientFailure(status: .disconnected) }
    let id = UUID()
    let token = generation
    let watchdog = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self, self.generation == token, self.pending[id] != nil else { return }
      self.close(.workerLost)
    }
    defer { watchdog.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      let proxy =
        connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] _ in
          Task { @MainActor in
            guard let self, self.generation == token else { return }
            self.close(.workerLost)
          }
        } as! WorkerProtocol
      proxy.exchange(message) { [weak self] reply in
        Task { @MainActor in
          guard let self, self.generation == token else { return }
          guard reply.bounded, reply.version == 1,
            reply.operation == message.operation, reply.interaction.isEmpty,
            reply.snapshot == nil, reply.remainingMilliseconds == 0,
            (reply.kind == "negotiated" && message.kind == "negotiate")
              || (reply.kind == "ack" && reply.sequence == 0
                && Status(rawValue: reply.value) != nil)
          else {
            self.close(.protocolViolation)
            return
          }
          self.pending.removeValue(forKey: id)?.resume(returning: reply)
        }
      }
    }
  }

  public func disconnect() { close(.disconnected) }

  private func armDeadline(_ operation: String, milliseconds: Int) {
    deadlines[operation]?.cancel()
    deadlines[operation] = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
      guard let self, self.operations[operation] != nil else { return }
      self.close(.workerLost)
    }
  }

  private func receive(_ event: Message) {
    guard let sequence = operations[event.operation] else { return }
    guard event.bounded, event.version == 1, event.snapshot == nil,
      event.sequence == sequence + 1,
      (event.kind == "progress" && event.value == "started" && event.interaction.isEmpty
        && event.remainingMilliseconds == 0)
        || (event.kind == "interaction" && ["selectKey", "touch"].contains(event.value)
          && UUID(uuidString: event.interaction)?.uuidString == event.interaction)
        || (event.kind == "terminal" && Status(rawValue: event.value) != nil
          && event.interaction.isEmpty
          && event.remainingMilliseconds == 0)
    else {
      close(.protocolViolation)
      return
    }
    operations[event.operation] = event.sequence
    if event.kind == "terminal" { forget(event.operation) }
    onEvent(event)
  }

  private func forget(_ operation: String) {
    operations.removeValue(forKey: operation)
    deadlines.removeValue(forKey: operation)?.cancel()
  }

  private func close(_ status: Status) {
    generation = UUID()
    ready = false
    workerPID = 0
    let old = connection
    connection = nil
    old?.invalidate()
    let replies = pending
    pending.removeAll()
    for continuation in replies.values {
      continuation.resume(throwing: ClientFailure(status: status))
    }
    let active = operations
    operations.removeAll()
    for task in deadlines.values { task.cancel() }
    deadlines.removeAll()
    for (operation, sequence) in active {
      onEvent(
        Message("terminal", operation: operation, value: status.rawValue, sequence: sequence + 1))
    }
  }
}
