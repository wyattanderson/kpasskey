import Foundation

/// rules_foreign_cc exposes an installation tree; extract only the runtime plugin.
@main struct SelectArtifact {
    static func main() throws {
        let args = CommandLine.arguments
        try FileManager.default.copyItem(atPath: args[1] + "/lib/krb5/plugins/preauth/pkinit.so", toPath: args[2])
    }
}
