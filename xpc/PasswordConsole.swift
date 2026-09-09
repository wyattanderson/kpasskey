import Darwin
import Foundation
import KPasskeyClient
import KPasskeyContract

/// Owns only the terminal read buffer; XPC and Foundation may make unavoidable secret copies.
func readPassword(until deadline: ContinuousClock.Instant, terminal: Int32? = nil) throws -> Data? {
  let tty = terminal.map { dup($0) } ?? open("/dev/tty", O_RDWR | O_NOCTTY)
  guard tty >= 0 else { throw CocoaError(.fileReadNoPermission) }
  defer { close(tty) }
  let originalFlags = fcntl(tty, F_GETFL)
  guard originalFlags >= 0, fcntl(tty, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
    throw CocoaError(.fileReadUnknown)
  }
  defer { _ = fcntl(tty, F_SETFL, originalFlags) }
  var original = termios()
  guard tcgetattr(tty, &original) == 0 else { throw CocoaError(.fileReadUnknown) }
  var hidden = original
  hidden.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG)
  withUnsafeMutableBytes(of: &hidden.c_cc) { bytes in
    bytes[Int(VMIN)] = 1
    bytes[Int(VTIME)] = 0
  }
  guard tcsetattr(tty, TCSANOW, &hidden) == 0 else { throw CocoaError(.fileReadUnknown) }
  tcflush(tty, TCIFLUSH)
  defer {
    tcflush(tty, TCIFLUSH)
    tcsetattr(tty, TCSANOW, &original)
    _ = "\n".withCString { write(tty, $0, 1) }
  }
  let prompt = "Password (Ctrl-C cancels): "
  _ = prompt.withCString { write(tty, $0, strlen($0)) }
  var bytes = [UInt8](repeating: 0, count: 4096)
  defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
  var count = 0
  while ContinuousClock.now < deadline {
    var byte: UInt8 = 0
    let countRead = read(tty, &byte, 1)
    if countRead < 0 && (errno == EAGAIN || errno == EINTR) {
      // Darwin poll rejects /dev/tty; this console-only wait preserves the interaction deadline.
      Thread.sleep(forTimeInterval: 0.01)
      continue
    }
    guard countRead == 1 else { return nil }
    defer { byte = 0 }
    switch byte {
    case 3, 4: return nil
    case 10, 13: return count == 0 ? nil : Data(bytes.prefix(count))
    case 8, 127: if count > 0 { count -= 1; bytes[count] = 0 }
    case 0: return nil
    default:
      guard count < bytes.count else { return nil }
      bytes[count] = byte
      count += 1
    }
  }
  return nil
}

@MainActor
func passwordConsole(_ client: WorkerClient, settings: Configuration) async throws {
  var terminal: Message?
  var prompt: Message?
  client.onEvent = { event in
    if event.kind == "interaction" { prompt = event }
    if event.kind == "terminal" { terminal = event }
    print("\(event.kind) \(event.value)")
  }
  let operation = UUID().uuidString
  let ack = try await client.start(Snapshot(configuration: settings), operation: operation)
  guard ack.value == "ok" else { throw ClientFailure(status: Status(rawValue: ack.value) ?? .protocolViolation) }
  while prompt == nil && terminal == nil { try await Task.sleep(for: .milliseconds(10)) }
  if let prompt, terminal == nil {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(prompt.remainingMilliseconds))
    var secret = try await Task.detached { try readPassword(until: deadline) }.value
    defer { if secret != nil { secret!.resetBytes(in: 0..<secret!.count) } }
    if let password = secret, terminal == nil {
      _ = try await client.respond(to: prompt, password: password)
    } else { _ = try await client.cancel(operation) }
  }
  while terminal == nil { try await Task.sleep(for: .milliseconds(10)) }
  guard let terminal else { return }
  if let ticket = terminal.ticket {
    print("principal \(ticket.principal)")
    print("cache \(ticket.cache)")
    print("expires \(Date(timeIntervalSince1970: TimeInterval(ticket.expires)))")
    print("renew_until \(ticket.renewUntil) forwardable \(ticket.forwardable)")
  }
  guard terminal.value == "ok", terminal.ticket != nil else {
    print("kerberos_error_code \(terminal.errorCode)")
    throw ClientFailure(status: Status(rawValue: terminal.value) ?? .protocolViolation)
  }
}
