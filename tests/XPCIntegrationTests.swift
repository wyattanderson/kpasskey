import BuildTestSupport
import Foundation
import Testing

@Test func embeddedWorkerLifecycleAndRelocation() throws {
  let manager = FileManager.default
  let root = URL(fileURLWithPath: try environment("TEST_TMPDIR"))
    .appendingPathComponent("XPC bundles with spaces \(UUID().uuidString)")
  try manager.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: root) }
  try run("/usr/bin/ditto", ["-x", "-k", try artifact("KPASSKEY_HARNESS").path, root.path])
  let original = root.appendingPathComponent("KPasskeyHarness.app")
  let hostPath = "Contents/MacOS/KPasskeyHarness"
  let workerPath = "Contents/XPCServices/Worker.xpc/Contents/MacOS/Worker"
  let workerInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf:
    original.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/Info.plist")), format: nil)
    as? [String: Any]
  #expect((workerInfo?["XPCService"] as? [String: Any])?["JoinExistingSession"] as? Bool == true)
  try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", original.path])
  if try environment("KPASSKEY_DEVELOPMENT") != "true" {
    // Default/release compilation has no ad-hoc identity fallback.
    #expect(throws: BuildTestFailure.self) {
      try run(original.appendingPathComponent(hostPath).path, ["--automatic"], environment: [:])
    }
    return
  }
  #expect(geteuid() != 0)
  let first = try run(
    original.appendingPathComponent(hostPath).path, ["--automatic"], environment: [:])
  #expect(first.contains("terminal ok"))
  let eof = try run(
    original.appendingPathComponent(hostPath).path, environment: [:], input: .nullDevice)
  #expect(eof.contains("terminal cancelled"))
  let moved = root.appendingPathComponent("Moved Host.app")
  try manager.moveItem(at: original, to: moved)
  try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", moved.path])
  for path in [hostPath, workerPath] {
    #expect(
      try dependencies(of: moved.appendingPathComponent(path)).allSatisfy {
        $0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/Library/")
          || $0.hasPrefix("@rpath/libswift")
          || ["libkrb5.3.3.dylib", "libk5crypto.3.1.dylib", "libcom_err.3.0.dylib",
              "libkrb5support.1.1.dylib", "libgssapi_krb5.2.2.dylib", "libcrypto.3.dylib",
              "libssl.3.dylib"].contains(String($0.dropFirst("@rpath/".count)))
      })
  }
  let output = try run(
    moved.appendingPathComponent(hostPath).path, ["--exercise"],
    environment: [:], directory: root)
  for expected in [
    "unsupported unsupportedVersion", "malformed protocolViolation", "concurrent busy",
    "stale staleInteraction", "replay protocolViolation", "cancel_ack ok bounded=true",
    "cancel_again ok", "decode_rejected", "exercise complete",
  ] { #expect(output.contains(expected), "Missing \(expected): \(output)") }
  let lines = output.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
  let identities = try #require(lines.first { $0.first == "connected" })
  #expect(identities[1].dropFirst(5) != identities[2].dropFirst(7))
  let expected: [String: String] = [
    "roundtrip": "ok", "repeat": "ok", "failure": "scriptedFailure", "cancel": "cancelled",
    "deadline": "deadlineExceeded", "disconnect": "disconnected", "kill": "workerLost",
    "reconnect": "ok",
    "invalidArchive": "workerLost", "afterInvalidArchive": "ok",
    "password-FIRST.INVALID": "kdcUnavailable", "password-SECOND.INVALID": "kdcUnavailable",
  ]
  for (label, status) in expected {
    let start = try #require(lines.first { $0.count == 4 && $0[0] == "start" && $0[1] == label })
    let events = lines.filter { $0.count == 5 && $0[0] == "event" && $0[1] == start[2] }
    #expect(events.compactMap { Int($0[2]) } == Array(1...events.count))
    #expect(events.filter { $0[3] == "terminal" }.map { $0[4] } == [status])
  }

  // Same claimed signing identifier, different actual code hash: the worker must reject it.
  let imposter = moved.appendingPathComponent("Contents/MacOS/Imposter")
  try manager.copyItem(at: moved.appendingPathComponent(hostPath), to: imposter)
  try run(
    "/usr/bin/codesign",
    [
      "--force", "--sign", "-", "--identifier", "org.kpasskey.harness",
      "--requirements", "=designated => identifier \"org.kpasskey.harness\" and true", imposter.path,
    ])
  do {
    try run(imposter.path, ["--automatic"], environment: [:])
    Issue.record("The differently signed peer was accepted")
  } catch let failure as BuildTestFailure {
    #expect(failure.description.contains("harness_error workerLost"))
  }
}
