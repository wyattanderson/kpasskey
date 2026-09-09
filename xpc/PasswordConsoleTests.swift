import Darwin
import Foundation
import Testing

@Test func secureTerminalInputAndDeadline() async throws {
  var master: Int32 = -1
  var slave: Int32 = -1
  #expect(openpty(&master, &slave, nil, nil, nil) == 0)
  defer { close(master); close(slave) }
  #expect(fcntl(master, F_SETFL, O_NONBLOCK) == 0)
  let outputFD = master
  func output() async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var bytes = [UInt8](repeating: 0, count: 256)
    while ContinuousClock.now < deadline {
      let count = read(outputFD, &bytes, bytes.count)
      if count > 0 { return String(decoding: bytes.prefix(count), as: UTF8.self) }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadUnknown)
  }
  var original = termios()
  #expect(tcgetattr(slave, &original) == 0)
  let input = slave
  let reader = Task.detached {
    try readPassword(until: .now.advanced(by: .seconds(2)), terminal: input)
  }
  // Waiting for the prompt ensures echo is disabled before sending synthetic input.
  #expect(try await output().contains("Password"))
  let synthetic = "synthetic-onlx\u{7f}y\n"
  _ = synthetic.withCString { write(master, $0, strlen($0)) }
  #expect(try await reader.value == Data("synthetic-only".utf8))
  #expect(try await !output().contains("synthetic"))
  var restored = termios()
  #expect(tcgetattr(slave, &restored) == 0)
  let changedFlags = tcflag_t(ECHO | ECHONL | ICANON | ISIG)
  #expect(restored.c_lflag & changedFlags == original.c_lflag & changedFlags)
  #expect(try readPassword(until: .now.advanced(by: .milliseconds(50)), terminal: slave) == nil)
  #expect(tcgetattr(slave, &restored) == 0)
  #expect(restored.c_lflag & changedFlags == original.c_lflag & changedFlags)
}
