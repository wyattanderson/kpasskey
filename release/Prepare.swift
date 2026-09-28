import CryptoKit
import Foundation
import Security

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
        let direct = args.count == 4 && args[1] == "dmg"
        guard direct || (args.count == 5 && ["unsigned", "signed"].contains(args[1])) else {
            throw ReleaseError(
                "Usage: prepare dmg INPUT.zip OUTPUT.dmg | "
                    + "unsigned|signed INPUT.zip OUTPUT_DIRECTORY vMAJOR.MINOR.PATCH"
            )
        }
        let tag = direct ? nil : args[4]
        let version = try tag.map { try releaseVersion($0) }
        let signed = args[1] == "signed"
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] ?? fileManager
            .currentDirectoryPath)
        let input = URL(fileURLWithPath: args[2], relativeTo: root).standardizedFileURL
        let output = URL(fileURLWithPath: args[3], relativeTo: root).standardizedFileURL
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("kpasskey-release-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try run("/usr/bin/ditto", ["-x", "-k", input.path, temporary.path])
        let app = temporary.appendingPathComponent("KPasskey.app")
        let worker = app.appendingPathComponent("Contents/XPCServices/Worker.xpc")
        var builtVersion: String?
        for bundle in [app, worker] {
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil
            ) as? [String: Any]
            guard let shortVersion = info?["CFBundleShortVersionString"] as? String,
                  info?["CFBundleVersion"] as? String == shortVersion,
                  builtVersion == nil || builtVersion == shortVersion
            else {
                throw ReleaseError("Application bundle versions do not match")
            }
            builtVersion = shortVersion
        }
        if let tag, let version, builtVersion != version {
            throw ReleaseError("Bundle version does not match \(tag); build with --embed_label=\(tag)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], reportOutput: true)
        if signed {
            try signAndNotarize(app: app, worker: worker, temporary: temporary)
        }
        let archive: URL
        if let tag {
            try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            archive = output.appendingPathComponent(
                "KPasskey-\(tag)-macos-arm64\(signed ? "" : "-unsigned").dmg"
            )
        } else {
            archive = output
        }
        guard !fileManager.fileExists(atPath: archive.path) else { throw ReleaseError("Output archive already exists") }
        try createDiskImage(app: app, at: archive, temporary: temporary)
        let digest = try SHA256.hash(data: Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        try Data("\(digest)  \(archive.lastPathComponent)\n".utf8).write(to: archive.appendingPathExtension("sha256"))
        print(archive.path)
    }

    static func createDiskImage(app: URL, at output: URL, temporary: URL) throws {
        let fileManager = FileManager.default
        let staging = temporary.appendingPathComponent("disk")
        let writable = temporary.appendingPathComponent("writable.dmg")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.moveItem(at: app, to: staging.appendingPathComponent("KPasskey.app"))
        try fileManager.createSymbolicLink(atPath: staging.appendingPathComponent("Applications").path,
                                           withDestinationPath: "/Applications")
        try run("/usr/bin/hdiutil", ["create", "-ov", "-format", "UDRW", "-fs", "HFS+",
                                     "-volname", "KPasskey", "-srcfolder", staging.path, "-noanyowners", writable.path])
        let mount = try attach(writable)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }

        // Finder has no supported Swift API for per-folder icon placement, so use
        // its system scripting interface for this narrowly scoped build step.
        let layout = """
        tell application "Finder"
          tell disk "KPasskey"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set bounds of container window to {100, 100, 700, 450}
            set arrangement of icon view options of container window to not arranged
            set icon size of icon view options of container window to 128
            set text size of icon view options of container window to 16
            set position of item "KPasskey.app" of container window to {170, 170}
            set position of item "Applications" of container window to {430, 170}
            close container window
          end tell
        end tell
        """
        try run("/usr/bin/osascript", ["-e", layout], reportOutput: true)
        try run("/bin/sync", [])
        try run("/usr/bin/hdiutil", ["detach", mount.path])
        try run("/usr/bin/hdiutil", ["convert", writable.path, "-format", "UDZO",
                                     "-imagekey", "zlib-level=9", "-o", output.path])
    }

    static func attach(_ image: URL) throws -> URL {
        let result = try run("/usr/bin/hdiutil", ["attach", "-plist", "-readwrite", "-noverify",
                                                  "-noautoopen", image.path], reportOutput: true)
        let plist = try PropertyListSerialization.propertyList(from: Data(result.utf8), format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]]
        guard let path = entities?.compactMap({ $0["mount-point"] as? String }).first else {
            throw ReleaseError("hdiutil did not report a mounted volume")
        }
        return URL(fileURLWithPath: path)
    }

    static func signAndNotarize(app: URL, worker: URL, temporary: URL) throws {
        // Fail before importing anything if the signing configuration is incomplete.
        let identity = try requiredEnvironment("APPLE_SIGNING_IDENTITY")
        let team = try requiredEnvironment("APPLE_TEAM_ID")
        let account = try requiredEnvironment("APPLE_ID")
        let password = try requiredEnvironment("APPLE_APP_PASSWORD")
        let p12Password = try requiredEnvironment("APPLE_CERTIFICATE_PASSWORD")
        guard identity.hasPrefix("Developer ID Application: ") else {
            throw ReleaseError("APPLE_SIGNING_IDENTITY must be the full Developer ID Application certificate name")
        }
        guard identity.hasSuffix("(\(team))") else {
            throw ReleaseError("APPLE_TEAM_ID does not match APPLE_SIGNING_IDENTITY")
        }
        guard let certificate = try Data(
            base64Encoded: requiredEnvironment("APPLE_CERTIFICATE_BASE64"),
            options: .ignoreUnknownCharacters
        ),
            !certificate.isEmpty
        else { throw ReleaseError("APPLE_CERTIFICATE_BASE64 must contain a base64 PKCS#12 certificate") }
        let keychain = temporary.appendingPathComponent("signing.keychain-db")
        let p12 = temporary.appendingPathComponent("certificate.p12")
        let keychainPassword = UUID().uuidString
        try certificate.write(to: p12)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        try run("/usr/bin/security", ["create-keychain", "-p", keychainPassword, keychain.path])
        defer { _ = try? run("/usr/bin/security", ["delete-keychain", keychain.path]) }
        try run("/usr/bin/security", ["set-keychain-settings", "-lut", "21600", keychain.path])
        try run("/usr/bin/security", ["unlock-keychain", "-p", keychainPassword, keychain.path])
        try run(
            "/usr/bin/security",
            ["import", p12.path, "-k", keychain.path, "-P", p12Password, "-T", "/usr/bin/codesign"]
        )
        try run(
            "/usr/bin/security",
            [
                "set-key-partition-list",
                "-S",
                "apple-tool:,apple:,codesign:",
                "-s",
                "-k",
                keychainPassword,
                keychain.path
            ]
        )
        try FileManager.default.removeItem(at: p12)

        // codesign --keychain selects the identity, but its certificate chain is
        // resolved through the user's search list. Restore that list before cleanup.
        var originalSearchList: CFArray?
        var signingKeychain: SecKeychain?
        guard SecKeychainCopySearchList(&originalSearchList) == errSecSuccess,
              let originalSearchList,
              SecKeychainOpen(keychain.path, &signingKeychain) == errSecSuccess,
              let signingKeychain,
              SecKeychainSetSearchList((Array(originalSearchList as [AnyObject]) + [signingKeychain]) as CFArray) ==
              errSecSuccess
        else { throw ReleaseError("Could not add the signing keychain to the user search list") }
        defer { SecKeychainSetSearchList(originalSearchList) }

        // The app's entire dynamic-code closure lives in these two directories.
        // Sign code inside out; --deep is for verification, never for signing.
        for directory in ["Contents/Frameworks", "Contents/XPCServices/Worker.xpc/Contents/PlugIns"] {
            let files = try FileManager.default.contentsOfDirectory(
                at: app.appendingPathComponent(directory), includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
            for file in files.sorted(by: { $0.path < $1.path }) {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    continue
                }
                guard ["dylib", "so"].contains(file.pathExtension)
                else { throw ReleaseError("Unexpected nested code: \(file.lastPathComponent)") }
                try sign(file, identity: identity, keychain: keychain)
            }
        }
        try sign(worker, identity: identity, keychain: keychain)
        try sign(app, identity: identity, keychain: keychain)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], reportOutput: true)
        // Exercises real Developer ID XPC authorization without a KDC or security key.
        let diagnostic = try run(
            app.appendingPathComponent("Contents/MacOS/KPasskey").path,
            ["--check-worker"],
            reportOutput: true
        )
        guard diagnostic.contains("separate process: true")
        else { throw ReleaseError("Signed XPC worker check failed") }
        try run("/usr/bin/xcrun", ["notarytool", "store-credentials", "release", "--keychain", keychain.path,
                                   "--apple-id", account, "--team-id", team, "--password", password])
        let submission = temporary.appendingPathComponent("notarization.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, submission.path])
        FileHandle.standardError.write(Data("Submitting signed app for notarization\n".utf8))
        let result = try run("/usr/bin/xcrun", [
            "notarytool",
            "submit",
            submission.path,
            "--keychain",
            keychain.path,
            "--keychain-profile",
            "release",
            "--wait",
            "--timeout",
            "30m",
            "--output-format",
            "json"
        ], reportOutput: true)
        let status = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        guard status?["status"] as? String == "Accepted"
        else { throw ReleaseError("Apple did not accept the notarization submission: \(result)") }
        try run("/usr/bin/xcrun", ["stapler", "staple", app.path], reportOutput: true)
        try run("/usr/bin/xcrun", ["stapler", "validate", app.path], reportOutput: true)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], reportOutput: true)
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path], reportOutput: true)
    }

    static func sign(_ file: URL, identity: String, keychain: URL) throws {
        FileHandle.standardError.write(Data("Signing \(file.lastPathComponent)\n".utf8))
        try run("/usr/bin/codesign", [
            "--force",
            "--sign",
            identity,
            "--keychain",
            keychain.path,
            "--options",
            "runtime",
            "--preserve-metadata=entitlements",
            "--timestamp",
            file.path
        ], reportOutput: true)
    }
}
