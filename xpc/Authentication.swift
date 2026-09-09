import Foundation
import KPasskeyContract
import Observation

/// Presentation and interaction policy shared by the native app and real-mode console.
/// Secrets are supplied for one response and are never part of observable state.
@MainActor @Observable
public final class Authentication {
  public private(set) var operation: String?
  public private(set) var prompt: Message?
  public private(set) var promptDeadline: Date?
  public private(set) var terminal: Message?
  public private(set) var ticket: TicketMetadata?
  public private(set) var message = "Ready to sign in."
  public private(set) var sending = false
  public private(set) var cancelling = false
  @ObservationIgnored private let client: WorkerClient
  @ObservationIgnored private var connected = false
  public var isRunning: Bool { operation != nil }

  public init(client: WorkerClient = WorkerClient()) {
    self.client = client
    client.onEvent = { [weak self] in self?.receive($0) }
  }

  public func start(_ configuration: Configuration) async {
    guard !isRunning else { return }
    guard configuration.valid else {
      message = Self.description(.configurationInvalid)
      return
    }
    let id = UUID().uuidString
    prepare(id)
    do {
      try await client.connect()
      guard operation == id else { return }
      connected = true
      let ack = try await client.start(Snapshot(configuration: configuration), operation: id)
      if ack.value != "ok" { fail(ack.value, operation: id) }
    } catch { fail(error, operation: id) }
  }

  func prepare(_ id: String) {
    operation = id
    terminal = nil
    prompt = nil
    promptDeadline = nil
    sending = false
    cancelling = false
    connected = false
    message = "Connecting…"
  }

  func receive(_ event: Message) {
    guard event.operation == operation else { return }
    switch event.kind {
    case "interaction":
      guard !cancelling else { return }
      prompt = event
      promptDeadline = Date().addingTimeInterval(Double(event.remainingMilliseconds) / 1000)
      message = Self.promptLabel(event)
    case "progress":
      prompt = nil
      promptDeadline = nil
      if !cancelling {
        message = switch event.value {
        case "acquiringArmor": "Establishing a secure connection…"
        case "touchKey": "Touch your security key."
        case "verifyOnDevice": "Verify your identity on your security key."
        default: "Signing in…"
        }
      }
    case "terminal":
      terminal = event
      if let published = event.ticket { ticket = published }
      message = Self.description(Status(rawValue: event.value) ?? .protocolViolation)
      operation = nil
      prompt = nil
      promptDeadline = nil
      sending = false
      cancelling = false
    default: break
    }
  }

  public static func promptLabel(_ event: Message) -> String {
    switch event.value {
    case "selectDevice": "Choose a security key"
    case "pin": "Security key PIN"
    default: "Password"
    }
  }

  public static func validSecret(_ secret: Data, for event: Message) -> Bool {
    guard !secret.isEmpty, !secret.contains(0) else { return false }
    switch event.value {
    case "password": return secret.count <= 4096
    case "pin":
      return secret.count <= 63
        && (String(data: secret, encoding: .utf8)?.unicodeScalars.count ?? 0) >= 4
    default: return false
    }
  }

  public func respond(to event: Message, secret: Data? = nil, device: Int? = nil) async {
    guard let id = operation, event.operation == id,
      prompt?.interaction == event.interaction, !sending, !cancelling else { return }
    let choice: String
    if event.value == "selectDevice", let device, event.choices.indices.contains(device) {
      choice = "device-\(device)"
    } else if let secret, Self.validSecret(secret, for: event) { choice = "" }
    else { return }
    sending = true
    // Consume before awaiting: a new prompt or terminal can precede this response's ack.
    prompt = nil
    promptDeadline = nil
    message = "Signing in…"
    do {
      let ack: Message
      if choice.isEmpty, let secret { ack = try await client.respond(to: event, password: secret) }
      else { ack = try await client.respond(to: event, value: choice) }
      if operation == id {
        sending = false
        if ack.value != "ok" {
          // End the operation; never leave a rejected prompt invisibly pending in the worker.
          fail(ack.value, operation: id)
          client.disconnect()
        }
      }
    } catch { fail(error, operation: id) }
  }

  public func cancel() async {
    guard let id = operation, !cancelling else { return }
    cancelling = true
    prompt = nil
    promptDeadline = nil
    message = "Cancelling…"
    if !connected {
      client.disconnect()
      fail(Status.cancelled.rawValue, operation: id)
      return
    }
    do {
      let ack = try await client.cancel(id)
      if ack.value != "ok" { fail(ack.value, operation: id) }
      // The terminal decides the outcome: publication may already have committed.
    } catch { fail(error, operation: id) }
  }

  public func disconnect() { client.disconnect() }

  private func fail(_ error: any Error, operation: String) {
    fail(((error as? ClientFailure)?.status ?? .workerLost).rawValue, operation: operation)
  }

  private func fail(_ value: String, operation: String) {
    receive(Message("terminal", operation: operation, value: value))
  }

  public static func description(_ status: Status) -> String {
    switch status {
    case .ok: "Signed in. Your ticket was published to macOS."
    case .cancelled: "Sign-in cancelled."
    case .deadlineExceeded: "Sign-in timed out. Try again when you’re ready."
    case .configurationInvalid: "Check your account, realm, and authentication settings."
    case .kdcUnavailable: "Couldn’t reach your realm. Check your network and settings."
    case .credentialsRejected: "Your credentials were rejected. Check them before trying again."
    case .keyAbsent: "Connect a USB security key and try again."
    case .wrongKey: "This key isn’t enrolled for your account. Try your enrolled key."
    case .deviceRemoved: "The security key was removed. Reconnect it and try again."
    case .pinInvalid: "Incorrect PIN. Check it before trying again; attempts are limited."
    case .pinBlocked: "The key’s PIN is blocked. Use the key vendor’s recovery process."
    case .pinAuthBlocked: "PIN entry is temporarily blocked. Reconnect the key before trying again."
    case .pinRequired: "This key requires a PIN. Configure it with the key vendor’s tools."
    case .uvUnavailable, .uvBlocked: "Verification on this key is unavailable or blocked."
    case .armorFailed: "Couldn’t establish realm trust. Check the realm and KDC CA certificate."
    case .passkeyRequired, .passkeyInvalid: "Passkey authentication couldn’t be verified for this account."
    case .publicationFailed: "Authentication succeeded, but the ticket couldn’t be published to macOS."
    case .workerLost, .disconnected:
      "The authentication service disconnected. The outcome may be unknown; check your tickets before retrying."
    case .busy: "The authentication service is busy. Wait a moment and try again."
    case .unexpectedPrompt: "The realm requested an unsupported authentication step."
    case .protocolViolation, .unsupportedVersion, .staleInteraction:
      "The authentication service rejected the exchange. Reopen the app and try again."
    case .deviceFailure: "Couldn’t communicate with the security key. Reconnect it and try again."
    case .authenticationFailed, .scriptedFailure: "Sign-in failed. Check your account and realm settings."
    }
  }
}
