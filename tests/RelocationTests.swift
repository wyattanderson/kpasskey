import BuildTestSupport
import Foundation
import Testing

@Test func signedSwiftExecutablesRunAfterRelocation() throws {
    let manager = FileManager.default
    let root = try URL(fileURLWithPath: environment("TEST_TMPDIR"))
        .appendingPathComponent("relocated build probes with spaces \(UUID().uuidString)")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    for directory in ["bin", "lib", "plugins"] {
        try manager.createDirectory(
            at: root.appendingPathComponent(directory), withIntermediateDirectories: true
        )
    }
    let krb = try artifact("KPASSKEY_KRB5")
    let crypto = try artifact("KPASSKEY_OPENSSL")
    for (tree, names) in [
        (
            krb,
            [
                "libkrb5.3.3", "libk5crypto.3.1", "libcom_err.3.0", "libkrb5support.1.1",
                "libgssapi_krb5.2.2"
            ]
        ),
        (crypto, ["libcrypto.3", "libssl.3"])
    ] {
        for name in names {
            try manager.copyItem(
                at: tree.appendingPathComponent("lib/\(name).dylib").resolvingSymlinksInPath(),
                to: root.appendingPathComponent("lib/\(name).dylib")
            )
        }
    }
    let plugin = root.appendingPathComponent("plugins/pkinit.so")
    try manager.copyItem(
        at: krb.appendingPathComponent("lib/krb5/plugins/preauth/pkinit.so").resolvingSymlinksInPath(),
        to: plugin
    )
    for (variable, name) in [
        ("KPASSKEY_BRIDGE_APP", "bridge_app"), ("KPASSKEY_DEPENDENCY_APP", "dependency_app")
    ] {
        // Runfiles are symlinks. Copy the executable itself, not a link back
        // into the build tree, so @executable_path resolves in the staged tree.
        let source = try artifact(variable).resolvingSymlinksInPath()
        let destination = root.appendingPathComponent("bin/\(name)")
        try manager.copyItem(at: source, to: destination)
        #expect(try destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        // Verify and execute the exact signed bytes, with no rpath rewriting,
        // re-signing, test frameworks, or inherited developer environment.
        #expect(try Data(contentsOf: source) == Data(contentsOf: destination))
        try run("/usr/bin/codesign", ["--verify", destination.path])
        let arguments = name == "dependency_app" ? [plugin.path] : []
        try run(destination.path, arguments, environment: [:], directory: root)
    }
}
