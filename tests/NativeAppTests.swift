import BuildTestSupport
import Foundation
import Testing

@Test func nativeBundlePeerIdentityAndRelocation() throws {
  let manager = FileManager.default
  let root = URL(fileURLWithPath: try environment("TEST_TMPDIR"))
    .appendingPathComponent("Native app with spaces \(UUID().uuidString)")
  try manager.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: root) }
  try run("/usr/bin/ditto", ["-x", "-k", try artifact("KPASSKEY_APP").path, root.path])
  let original = root.appendingPathComponent("KPasskey.app")
  let moved = root.appendingPathComponent("Relocated KPasskey.app")
  try manager.moveItem(at: original, to: moved)
  try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", moved.path])
  let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf:
    moved.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])
  #expect(info["CFBundleIdentifier"] as? String == "org.kpasskey.KPasskey")
  #expect(info["CFBundleShortVersionString"] as? String == "0.1")
  #expect(info["CFBundleVersion"] as? String == "0.1.1")
  #expect(info["LSUIElement"] as? Bool == true)
  let workerInfo = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf:
    moved.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/Info.plist")),
    format: nil) as? [String: Any])
  #expect(workerInfo["CFBundleIdentifier"] as? String == "org.kpasskey.KPasskey.worker")
  #expect((workerInfo["XPCService"] as? [String: Any])?["JoinExistingSession"] as? Bool == true)
  for plugin in ["kpasskey.dylib", "pkinit.so"] {
    #expect(manager.fileExists(atPath: moved.appendingPathComponent("Contents/PlugIns/" + plugin).path))
  }
  for resource in ["sky3.png", "skycnfc.png", "yk5cnfc.png"] {
    #expect(manager.fileExists(atPath: moved.appendingPathComponent("Contents/Resources/icons/" + resource).path))
    #expect(!manager.fileExists(atPath: moved.appendingPathComponent("Contents/Resources/" + resource).path))
  }
  for license in ["libcbor-LICENSE", "libfido2-LICENSE", "MIT-krb5-NOTICE", "OpenSSL-LICENSE", "YUBICO-NOTICE.txt", "YUBIOATH-APACHE-2.0.txt", "zlib-LICENSE"] {
    #expect(manager.fileExists(atPath: moved.appendingPathComponent("Contents/Resources/licenses/" + license).path))
    #expect(!manager.fileExists(atPath: moved.appendingPathComponent("Contents/Resources/" + license).path))
  }
  let executable = moved.appendingPathComponent("Contents/MacOS/KPasskey")
  if try environment("KPASSKEY_DEVELOPMENT") == "true" {
    let output = try run(executable.path, ["--check-worker"], environment: [:])
    #expect(output.contains("separate process: true"))
    #expect(output.contains("Device inventory available: true"))
    let imposter = moved.appendingPathComponent("Contents/MacOS/Imposter")
    try manager.copyItem(at: executable, to: imposter)
    try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "org.kpasskey.KPasskey",
      "--requirements", "=designated => identifier \"org.kpasskey.KPasskey\" and true", imposter.path])
    #expect(throws: BuildTestFailure.self) {
      try run(imposter.path, ["--check-worker"], environment: [:])
    }
  } else {
    #expect(throws: BuildTestFailure.self) {
      try run(executable.path, ["--check-worker"], environment: [:])
    }
  }
}
