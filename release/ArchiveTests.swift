import Foundation
import Testing

@Test func releaseArchiveValidatesStampAndChecksum() throws {
    let fileManager = FileManager.default
    let root = try URL(fileURLWithPath: requiredEnvironment("TEST_TMPDIR"))
        .appendingPathComponent("Release archive test")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let runfiles = try URL(fileURLWithPath: requiredEnvironment("TEST_SRCDIR"))
        .appendingPathComponent(requiredEnvironment("TEST_WORKSPACE"))
    let app = try runfiles.appendingPathComponent(requiredEnvironment("APP"))
    let archive = try runfiles.appendingPathComponent(requiredEnvironment("DMG"))
    let prepare = try runfiles.appendingPathComponent(requiredEnvironment("PREPARE")).path
    try run("/usr/bin/ditto", ["-x", "-k", app.path, root.path])
    let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf:
        root.appendingPathComponent("KPasskey.app/Contents/Info.plist")), format: nil) as? [String: Any])
    let version = try #require(info["CFBundleShortVersionString"] as? String)
    #expect(fileManager.fileExists(atPath: archive.path))
    #expect(archive.pathExtension == "dmg")
    try run("/usr/bin/hdiutil", ["verify", archive.path])
    let mount = root.appendingPathComponent("mounted")
    try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
    try run(
        "/usr/bin/hdiutil",
        ["attach", "-readonly", "-noverify", "-noautoopen", "-mountpoint", mount.path, archive.path]
    )
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
    #expect(fileManager.fileExists(atPath: mount.appendingPathComponent("KPasskey.app").path))
    #expect(try fileManager
        .destinationOfSymbolicLink(atPath: mount.appendingPathComponent("Applications").path) == "/Applications")
    #expect(fileManager.fileExists(atPath: mount.appendingPathComponent(".DS_Store").path))
    let checksum = archive.appendingPathExtension("sha256")
    #expect(try run("/usr/bin/shasum", ["-a", "256", "-c", checksum.path],
                    directory: archive.deletingLastPathComponent()).contains(": OK"))
    // A tag mismatch must fail before emitting any distribution files.
    let mismatch = root.appendingPathComponent("mismatch")
    let wrongTag = version == "9.9.9" ? "v8.8.8" : "v9.9.9"
    #expect(throws: ReleaseError.self) { try run(prepare, ["unsigned", app.path, mismatch.path, wrongTag]) }
    #expect(!fileManager.fileExists(atPath: mismatch.path))
    // Never silently fall back to unsigned when signing is requested.
    #expect(throws: ReleaseError.self) {
        try run("/usr/bin/env", ["-i", prepare, "signed", app.path, mismatch.path, "v\(version)"])
    }
    #expect(!fileManager.fileExists(atPath: mismatch.path))
}
