import Foundation
import Testing

@Test func releaseArchiveValidatesStampAndChecksum() throws {
  let fm = FileManager.default
  let root = URL(fileURLWithPath: try requiredEnvironment("TEST_TMPDIR")).appendingPathComponent("Release archive test")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let runfiles = URL(fileURLWithPath: try requiredEnvironment("TEST_SRCDIR"))
    .appendingPathComponent(try requiredEnvironment("TEST_WORKSPACE"))
  let app = runfiles.appendingPathComponent(try requiredEnvironment("APP"))
  let archive = runfiles.appendingPathComponent(try requiredEnvironment("DMG"))
  let prepare = runfiles.appendingPathComponent(try requiredEnvironment("PREPARE")).path
  try run("/usr/bin/ditto", ["-x", "-k", app.path, root.path])
  let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf:
    root.appendingPathComponent("KPasskey.app/Contents/Info.plist")), format: nil) as? [String: Any])
  let version = try #require(info["CFBundleShortVersionString"] as? String)
  #expect(fm.fileExists(atPath: archive.path))
  #expect(archive.pathExtension == "dmg")
  try run("/usr/bin/hdiutil", ["verify", archive.path])
  let mount = root.appendingPathComponent("mounted")
  try fm.createDirectory(at: mount, withIntermediateDirectories: true)
  try run("/usr/bin/hdiutil", ["attach", "-readonly", "-noverify", "-noautoopen", "-mountpoint", mount.path, archive.path])
  defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
  #expect(fm.fileExists(atPath: mount.appendingPathComponent("KPasskey.app").path))
  #expect(try fm.destinationOfSymbolicLink(atPath: mount.appendingPathComponent("Applications").path) == "/Applications")
  #expect(fm.fileExists(atPath: mount.appendingPathComponent(".DS_Store").path))
  let checksum = archive.appendingPathExtension("sha256")
  #expect(try run("/usr/bin/shasum", ["-a", "256", "-c", checksum.path],
    directory: archive.deletingLastPathComponent()).contains(": OK"))
  // A tag mismatch must fail before emitting any distribution files.
  let mismatch = root.appendingPathComponent("mismatch")
  let wrongTag = version == "9.9.9" ? "v8.8.8" : "v9.9.9"
  #expect(throws: ReleaseError.self) { try run(prepare, ["unsigned", app.path, mismatch.path, wrongTag]) }
  #expect(!fm.fileExists(atPath: mismatch.path))
  // Never silently fall back to unsigned when signing is requested.
  #expect(throws: ReleaseError.self) {
    try run("/usr/bin/env", ["-i", prepare, "signed", app.path, mismatch.path, "v\(version)"])
  }
  #expect(!fm.fileExists(atPath: mismatch.path))
}
