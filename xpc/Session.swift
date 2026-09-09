import Foundation
import KPasskeyContract

/// All state and timers run on the main actor; XPC dispatch never waits for an interaction.
@MainActor
public final class WorkerSession: NSObject, WorkerProtocol {
  // One native operation process-wide, including one draining after cancellation.
  private static var kerberosBusy = false
  private var gate: PublicationGate?
  private var nativeWork: Task<Void, Never>?
  private var passkeyInteraction: PasskeyInteraction?
  private var deviceCount = 0
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
  private let terminateBlockedWorker: @MainActor () -> Void

  public init(terminateBlockedWorker: @escaping @MainActor () -> Void = {},
              emit: @escaping @MainActor (Message) -> Void) {
    self.emit = emit
    self.terminateBlockedWorker = terminateBlockedWorker
  }

  nonisolated public func exchange(_ message: Message, reply: @escaping @Sendable (Message) -> Void)
  {
    Task { @MainActor in reply(handle(message)) }
  }

  public func handle(_ message: Message) -> Message {
    func answer(_ status: Status, kind: String = "ack") -> Message {
      Message(kind, operation: message.operation, value: status.rawValue)
    }
    guard connected, message.validCommand else { return answer(.protocolViolation) }
    guard message.version == 3 else { return answer(.unsupportedVersion) }
    if message.kind == "negotiate" {
      negotiated = true
      return Message("negotiated", value: "fake,password,passkey", sequence: Int(getpid()))
    }
    guard negotiated else { return answer(.protocolViolation) }
    switch message.kind {
    case "start":
      guard active == nil, !Self.kerberosBusy else { return answer(.busy) }
      guard used.count < 1024, used.insert(message.operation).inserted else {
        return answer(.protocolViolation)
      }
      active = message
      expires = .now.advanced(by: .milliseconds(message.snapshot!.timeoutMilliseconds))
      sequence = 0
      event("progress", value: "started")
      if message.snapshot!.configuration != nil {
        Self.kerberosBusy = true
        gate = PublicationGate(deadline: expires)
        if message.snapshot!.configuration!.mode == .passkey { beginNative() }
        else { prompt("password") }
      } else { prompt("selectKey") }
      let milliseconds = message.snapshot!.timeoutMilliseconds
      deadline = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
        self?.stop(.deadlineExceeded)
      }
      return answer(.ok)
    case "respond":
      if active != nil && ContinuousClock.now >= expires { stop(.deadlineExceeded) }
      guard active?.operation == message.operation, interaction == message.interaction else {
        return answer(.staleInteraction)
      }
      if let passkeyInteraction {
        guard (stage == "pin" && message.secret != nil && message.secret!.count <= 63)
          || (stage == "selectDevice" && message.secret == nil
            && (0..<deviceCount).contains(where: { message.value == "device-\($0)" }))
        else { return answer(.protocolViolation) }
        interaction = ""
        stage = "authenticating"
        passkeyInteraction.respond(message)
        return answer(.ok)
      }
      if stage == "password" {
        guard let secret = message.secret, message.value.isEmpty,
          active?.snapshot?.configuration != nil, gate != nil else {
          return answer(.protocolViolation)
        }
        beginNative(password: secret)
        return answer(.ok)
      }
      guard
        message.secret == nil && ((stage == "selectKey" && message.value == "key-1")
          || (stage == "touch" && message.value == "continue"))
      else { return answer(.protocolViolation) }
      if stage == "selectKey" {
        prompt("touch")
      } else {
        finish(active?.snapshot?.outcome == "success" ? .ok : .scriptedFailure)
      }
      return answer(.ok)
    case "cancel":
      if active?.operation == message.operation { stop(.cancelled) }
      return answer(.ok)
    default: return answer(.protocolViolation)
    }
  }

  private func beginNative(password: Data? = nil) {
    guard let configuration = active?.snapshot?.configuration, let gate else { return }
    interaction = ""
    stage = "authenticating"
    event("progress", value: stage)
    let bridge = PasskeyInteraction(gate: gate, deadline: expires) { [weak self] stage, choices in
      Task { @MainActor in
        guard let self, self.gate === gate, self.active != nil else { return }
        if ["pin", "selectDevice"].contains(stage) {
          self.deviceCount = choices.count
          self.prompt(stage, choices: choices)
        } else { self.event("progress", value: stage) }
      }
    }
    if configuration.mode == .passkey { passkeyInteraction = bridge }
    nativeWork = Task { [self] in
      let result = await Task.detached {
        Result {
          if let password { return try acquirePassword(configuration, password: password, gate: gate) }
          return try acquirePasskey(configuration, interaction: bridge)
        }
      }.value
      nativeWork = nil
      Self.kerberosBusy = false
      self.gate = nil
      passkeyInteraction = nil
      guard active != nil else { return }
      switch result {
      case .success(let ticket): finish(.ok, ticket: ticket)
      case .failure(let error):
        let failure = error as? KerberosFailure ?? KerberosFailure(.authenticationFailed)
        finish(failure.status, code: failure.code)
      }
    }
  }

  public func disconnect() {
    connected = false
    stop(.disconnected)
    deadline?.cancel()
    deadline = nil
    active = nil
    interaction = ""
    used.removeAll()
  }

  private func stop(_ status: Status) {
    // Once publication begins, cancellation cannot turn a committed ticket into a cancelled result.
    if let gate, !gate.cancel() { return }
    passkeyInteraction?.cancel()
    if let gate, nativeWork != nil {
      Task { [self] in
        try? await Task.sleep(for: .milliseconds(750))
        if self.gate === gate && nativeWork != nil { terminateBlockedWorker() }
      }
    }
    if gate != nil && nativeWork == nil { Self.kerberosBusy = false; gate = nil }
    finish(status)
  }

  private func prompt(_ stage: String, choices: [String] = []) {
    self.stage = stage
    interaction = UUID().uuidString
    event("interaction", value: stage, choices: choices)
  }

  private func event(_ kind: String, value: String, ticket: TicketMetadata? = nil, code: Int32 = 0,
                     choices: [String] = []) {
    guard connected, let active else { return }
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
              Int(ContinuousClock.now.duration(to: expires) / .milliseconds(1)))) : 0,
        ticket: ticket, errorCode: code, choices: choices))
  }

  private func finish(_ status: Status, ticket: TicketMetadata? = nil, code: Int32 = 0) {
    guard active != nil else { return }
    deadline?.cancel()
    deadline = nil
    event("terminal", value: status.rawValue, ticket: ticket, code: code)
    active = nil
    interaction = ""
  }
}
