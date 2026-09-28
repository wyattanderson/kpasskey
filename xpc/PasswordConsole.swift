import Darwin
import Foundation
import KPasskeyClient
import KPasskeyContract

/// Owns only the terminal read buffer; XPC and Foundation may make unavoidable secret copies.
func readPassword(until deadline: ContinuousClock.Instant, terminal: Int32? = nil,
                  label: String = "Password") throws -> Data? {
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
    let prompt = label + " (Ctrl-C cancels): "
    _ = prompt.withCString { write(tty, $0, strlen($0)) }
    var bytes = [UInt8](repeating: 0, count: 4096)
    defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    var count = 0
    while ContinuousClock.now < deadline, !Task.isCancelled {
        var byte: UInt8 = 0
        let countRead = read(tty, &byte, 1)
        if countRead < 0, errno == EAGAIN || errno == EINTR {
            // Darwin poll rejects /dev/tty; this console-only wait preserves the interaction deadline.
            Thread.sleep(forTimeInterval: 0.01)
            continue
        }
        guard countRead == 1 else { return nil }
        defer { byte = 0 }
        switch byte {
        case 3, 4: return nil
        case 10, 13: return count == 0 ? nil : Data(bytes.prefix(count))
        case 8, 127:
            if count > 0 {
                count -= 1
                bytes[count] = 0
            }
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
    let authentication = Authentication(client: client)
    var input: Task<Data?, any Error>?
    defer { input?.cancel() }
    await authentication.start(settings)
    var lastMessage = ""
    while authentication.isRunning {
        if authentication.message != lastMessage {
            lastMessage = authentication.message
            print(lastMessage)
        }

        guard let current = authentication.prompt else {
            try await Task.sleep(for: .milliseconds(10))
            continue
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(current.remainingMilliseconds))
        let label: String
        if current.value == "selectDevice" {
            for choice in current.choices {
                print(choice)
            }
            label = "Key number"
        } else {
            label = Authentication.promptLabel(current)
        }
        let read = Task.detached { try readPassword(until: deadline, label: label) }
        input = read
        let stopRead = Task {
            while authentication.isRunning, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            read.cancel()
        }
        defer { stopRead.cancel() }
        var secret = try await read.value
        input = nil
        defer {
            secret?.withUnsafeMutableBytes {
                _ = memset_s($0.baseAddress, $0.count, 0, $0.count)
            }
        }

        if let password = secret, authentication.isRunning {
            if current.value == "selectDevice" {
                guard let text = String(data: password, encoding: .utf8), let number = Int(text),
                      (1 ... current.choices.count).contains(number)
                else {
                    await authentication.cancel()
                    continue
                }
                await authentication.respond(to: current, device: number - 1)
            } else if Authentication.validSecret(password, for: current) {
                await authentication.respond(to: current, secret: password)
            } else {
                await authentication.cancel()
            }
        } else {
            await authentication.cancel()
        }
    }

    guard let terminal = authentication.terminal else { throw ClientFailure(status: .configurationInvalid) }
    print("terminal \(terminal.value)")
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
