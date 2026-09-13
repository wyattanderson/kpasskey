import CryptoKit
import Foundation

@main struct Prepare {
  static func main() {
    do { try execute() }
    catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }

  static func execute() throws {
    let args = CommandLine.arguments
    guard args.count == 5, ["unsigned", "signed"].contains(args[1]) else {
      throw ReleaseError("Usage: prepare unsigned|signed INPUT.zip OUTPUT_DIRECTORY vMAJOR.MINOR.PATCH")
    }
    let version = try releaseVersion(args[4])
    let signed = args[1] == "signed"
    let fm = FileManager.default
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] ?? fm.currentDirectoryPath)
    let input = URL(fileURLWithPath: args[2], relativeTo: root).standardizedFileURL
    let output = URL(fileURLWithPath: args[3], relativeTo: root).standardizedFileURL
    let temporary = fm.temporaryDirectory.appendingPathComponent("kpasskey-release-\(UUID().uuidString)")
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    try run("/usr/bin/ditto", ["-x", "-k", input.path, temporary.path])
    let app = temporary.appendingPathComponent("KPasskey.app")
    let worker = app.appendingPathComponent("Contents/XPCServices/Worker.xpc")
    for bundle in [app, worker] {
      let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
      guard info?["CFBundleShortVersionString"] as? String == version,
        info?["CFBundleVersion"] as? String == version else {
        throw ReleaseError("Bundle version does not match \(args[4]); build with --embed_label=\(args[4])")
      }
    }
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    if signed { try signAndNotarize(app: app, worker: worker, temporary: temporary) }
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let archive = output.appendingPathComponent("KPasskey-\(args[4])-macos-arm64\(signed ? "" : "-unsigned").zip")
    guard !fm.fileExists(atPath: archive.path) else { throw ReleaseError("Output archive already exists") }
    try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path])
    let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
    try Data("\(digest)  \(archive.lastPathComponent)\n".utf8).write(to: archive.appendingPathExtension("sha256"))
    print(archive.path)
  }

  static func signAndNotarize(app: URL, worker: URL, temporary: URL) throws {
    // Fail before importing anything if the signing configuration is incomplete.
    let identity = try requiredEnvironment("APPLE_SIGNING_IDENTITY")
    let team = try requiredEnvironment("APPLE_TEAM_ID")
    let account = try requiredEnvironment("APPLE_ID")
    let password = try requiredEnvironment("APPLE_APP_PASSWORD")
    let p12Password = try requiredEnvironment("APPLE_CERTIFICATE_PASSWORD")
    guard identity.hasPrefix("Developer ID Application: "), identity.hasSuffix("(\(team))"),
      let certificate = Data(base64Encoded: try requiredEnvironment("APPLE_CERTIFICATE_BASE64"), options: .ignoreUnknownCharacters)
    else { throw ReleaseError("Expected a Developer ID Application identity and a base64 PKCS#12 certificate") }
    let keychain = temporary.appendingPathComponent("signing.keychain-db")
    let p12 = temporary.appendingPathComponent("certificate.p12")
    let keychainPassword = UUID().uuidString
    try certificate.write(to: p12)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
    try run("/usr/bin/security", ["create-keychain", "-p", keychainPassword, keychain.path])
    defer { _ = try? run("/usr/bin/security", ["delete-keychain", keychain.path]) }
    try run("/usr/bin/security", ["set-keychain-settings", "-lut", "21600", keychain.path])
    try run("/usr/bin/security", ["unlock-keychain", "-p", keychainPassword, keychain.path])
    try run("/usr/bin/security", ["import", p12.path, "-k", keychain.path, "-P", p12Password, "-T", "/usr/bin/codesign"])
    try run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychainPassword, keychain.path])
    try FileManager.default.removeItem(at: p12)

    // The app's entire dynamic-code closure lives in these two directories.
    // Sign code inside out; --deep is for verification, never for signing.
    for directory in ["Contents/Frameworks", "Contents/PlugIns"] {
      let files = try FileManager.default.contentsOfDirectory(
        at: app.appendingPathComponent(directory), includingPropertiesForKeys: [.isSymbolicLinkKey])
      for file in files.sorted(by: { $0.path < $1.path }) {
        if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
        guard ["dylib", "so"].contains(file.pathExtension) else { throw ReleaseError("Unexpected nested code: \(file.lastPathComponent)") }
        try sign(file, identity: identity, keychain: keychain)
      }
    }
    try sign(worker, identity: identity, keychain: keychain)
    try sign(app, identity: identity, keychain: keychain)
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    // Exercises real Developer ID XPC authorization without a KDC or security key.
    let diagnostic = try run(app.appendingPathComponent("Contents/MacOS/KPasskey").path, ["--check-worker"])
    guard diagnostic.contains("separate process: true") else { throw ReleaseError("Signed XPC worker check failed") }
    try run("/usr/bin/xcrun", ["notarytool", "store-credentials", "release", "--keychain", keychain.path,
      "--apple-id", account, "--team-id", team, "--password", password])
    let submission = temporary.appendingPathComponent("notarization.zip")
    try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, submission.path])
    let result = try run("/usr/bin/xcrun", ["notarytool", "submit", submission.path,
      "--keychain", keychain.path, "--keychain-profile", "release", "--wait", "--timeout", "30m", "--output-format", "json"])
    let status = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
    guard status?["status"] as? String == "Accepted" else { throw ReleaseError("Apple did not accept the notarization submission") }
    try run("/usr/bin/xcrun", ["stapler", "staple", app.path])
    try run("/usr/bin/xcrun", ["stapler", "validate", app.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path])
  }

  static func sign(_ file: URL, identity: String, keychain: URL) throws {
    try run("/usr/bin/codesign", ["--force", "--sign", identity, "--keychain", keychain.path,
      "--options", "runtime", "--timestamp", file.path])
  }
}
