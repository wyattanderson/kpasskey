import Foundation
import KPasskeyContract

/// All state and timers run on the main actor; XPC dispatch never waits for an interaction.
@MainActor
public final class FakeSession: NSObject, WorkerProtocol {
  private var negotiated = false
  private var connected = true
  private var active: Message?
  private var interaction = ""
  private var stage = ""
  private var sequence = 0
  private var deadline: Task<Void, Never>?
  private var expires = ContinuousClock.now
  // Bounded replay protection: reconnect after 1,024 operations.
  private var used = Set<String>()
  private let emit: @MainActor (Message) -> Void

  public init(emit: @escaping @MainActor (Message) -> Void) { self.emit = emit }

  nonisolated public func exchange(_ message: Message, reply: @escaping @Sendable (Message) -> Void)
  {
    Task { @MainActor in reply(handle(message)) }
  }

  public func handle(_ message: Message) -> Message {
    func answer(_ status: Status, kind: String = "ack") -> Message {
      Message(kind, operation: message.operation, value: status.rawValue)
    }
    guard connected, message.validCommand else { return answer(.protocolViolation) }
    guard message.version == 1 else { return answer(.unsupportedVersion) }
    if message.kind == "negotiate" {
      negotiated = true
      return Message("negotiated", value: "fake", sequence: Int(getpid()))
    }
    guard negotiated else { return answer(.protocolViolation) }
    switch message.kind {
    case "start":
      guard active == nil else { return answer(.busy) }
      guard used.count < 1024, used.insert(message.operation).inserted else {
        return answer(.protocolViolation)
      }
      active = message
      expires = .now.advanced(by: .milliseconds(message.snapshot!.timeoutMilliseconds))
      sequence = 0
      event("progress", value: "started")
      prompt("selectKey")
      let milliseconds = message.snapshot!.timeoutMilliseconds
      deadline = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
        self?.finish(.deadlineExceeded)
      }
      return answer(.ok)
    case "respond":
      if active != nil && ContinuousClock.now >= expires { finish(.deadlineExceeded) }
      guard active?.operation == message.operation, interaction == message.interaction else {
        return answer(.staleInteraction)
      }
      guard
        (stage == "selectKey" && message.value == "key-1")
          || (stage == "touch" && message.value == "continue")
      else { return answer(.protocolViolation) }
      if stage == "selectKey" {
        prompt("touch")
      } else {
        finish(active?.snapshot?.outcome == "success" ? .ok : .scriptedFailure)
      }
      return answer(.ok)
    case "cancel":
      if active?.operation == message.operation { finish(.cancelled) }
      return answer(.ok)
    default: return answer(.protocolViolation)
    }
  }

  public func disconnect() {
    connected = false
    deadline?.cancel()
    deadline = nil
    active = nil
    interaction = ""
    used.removeAll()
  }

  private func prompt(_ stage: String) {
    self.stage = stage
    interaction = UUID().uuidString
    event("interaction", value: stage)
  }

  private func event(_ kind: String, value: String) {
    guard let active else { return }
    sequence += 1
    emit(
      Message(
        kind, operation: active.operation, interaction: kind == "interaction" ? interaction : "",
        value: value, sequence: sequence,
        remainingMilliseconds: kind == "interaction"
          ? max(
            0,
            min(
              30_000,
              Int(ContinuousClock.now.duration(to: expires) / .milliseconds(1)))) : 0))
  }

  private func finish(_ status: Status) {
    guard active != nil else { return }
    deadline?.cancel()
    deadline = nil
    event("terminal", value: status.rawValue)
    active = nil
    interaction = ""
  }
}
