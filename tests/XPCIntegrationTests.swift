import BuildTestSupport
import CMITKerberos
import Foundation
import PasskeyWire
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
  for (file, entry) in [("kpasskey.dylib", "clpreauth_kpasskey_initvt"),
                         ("pkinit.so", "clpreauth_pkinit_initvt")] {
    let path = moved.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/PlugIns/" + file)
    let handle = try #require(dlopen(path.path, RTLD_NOW | RTLD_LOCAL))
    defer { dlclose(handle) }
    #expect(dlsym(handle, entry) != nil)
    let initialize: @convention(c) (UnsafeMutablePointer<krb5_context?>?) -> Int32 = krb5_init_context
    #expect(dlsym(handle, "krb5_init_context") == unsafeBitCast(initialize,
      to: UnsafeMutableRawPointer.self))
    #expect(try dependencies(of: path).allSatisfy {
      $0.hasPrefix("@rpath/") || $0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/Library/")
    })
  }
  try verifyPasskeyLoader(moved.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/PlugIns/kpasskey.dylib"))
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
    "invalidPasskeyTrust": "configurationInvalid",
  ]
  for (label, status) in expected {
    let start = try #require(lines.first { $0.count == 4 && $0[0] == "start" && $0[1] == label })
    let events = lines.filter { $0.count == 5 && $0[0] == "event" && $0[1] == start[2] }
    #expect(events.compactMap { Int($0[2]) } == Array(1...events.count))
    #expect(events.filter { $0[3] == "terminal" }.map { $0[4] } == [status])
  }

  // Same claimed signing identifier, different executable path: the worker must reject it.
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

private func verifyPasskeyLoader(_ plugin: URL) throws {
  var profile: profile_t?
  try #require(profile_init(nil, &profile) == 0)
  let p = try #require(profile)
  defer { profile_abandon(p) }
  for (key, value) in [("module", "kpasskey:" + plugin.path), ("enable_only", "kpasskey")] {
    let strings = ["plugins", "clpreauth", key].map { (name: String) in strdup(name)! }
    defer { strings.forEach { free($0) } }
    var names = strings.map { Optional(UnsafePointer($0)) } + [nil]
    try #require(profile_add_relation(p, &names, value) == 0)
  }
  var context: krb5_context?
  try #require(krb5_init_context_profile(p, KRB5_INIT_CONTEXT_SECURE, &context) == 0)
  let ctx = try #require(context)
  defer { krb5_free_context(ctx) }
  var client: krb5_principal?
  var server: krb5_principal?
  try #require(krb5_parse_name(ctx, "synthetic@EXAMPLE.INVALID", &client) == 0)
  defer { krb5_free_principal(ctx, client) }
  try #require(krb5_parse_name(ctx, "krbtgt/EXAMPLE.INVALID@EXAMPLE.INVALID", &server) == 0)
  defer { krb5_free_principal(ctx, server) }
  var exchange: krb5_init_creds_context?
  try #require(krb5_init_creds_init(ctx, client, nil, nil, 0, nil, &exchange) == 0)
  defer { krb5_init_creds_free(ctx, exchange) }
  var input = krb5_data(), output = krb5_data(), realm = krb5_data()
  var flags: UInt32 = 0
  try #require(krb5_init_creds_step(ctx, exchange, &input, &output, &realm, &flags) == 0)
  krb5_free_data_contents(ctx, &output); krb5_free_data_contents(ctx, &realm)
  output = krb5_data(); realm = krb5_data()
  defer { krb5_free_data_contents(ctx, &output); krb5_free_data_contents(ctx, &realm) }
  // Synthetic PREAUTH_REQUIRED offers PA 153. No network, device or cache writes.
  // Reaching the plugin's missing-armor guard proves MIT loaded and invoked it.
  var error = krb5_error()
  error.error = 25; error.stime = Int32(Date().timeIntervalSince1970)
  error.client = client; error.server = server
  let padata: [UInt8] = [0x30, 0x0c, 0x30, 0x0a, 0xa1, 0x04, 0x02, 0x02,
                        0x00, 0x99, 0xa2, 0x02, 0x04, 0x00]
  try padata.withUnsafeBytes { bytes in
    error.e_data = krb5_data(magic: 0, length: UInt32(bytes.count),
      data: UnsafeMutablePointer(mutating: bytes.baseAddress!.assumingMemoryBound(to: CChar.self)))
    try #require(krb5_mk_error(ctx, &error, &input) == 0)
  }
  defer { krb5_free_data_contents(ctx, &input) }
  #expect(krb5_init_creds_step(ctx, exchange, &input, &output, &realm, &flags) == WireError.armor.rawValue)
}
