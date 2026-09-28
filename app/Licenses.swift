import Foundation
import SwiftUI

private let bundledLicenses: String = {
    let notices: [String] = (Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "licenses") ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "\(url.lastPathComponent)\n\n\(text)"
        }
    return notices.isEmpty ? "No bundled open-source licenses were found." : notices
        .joined(separator: "\n\n────────────────────────────────────────\n\n")
}()

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    private let info = Bundle.main.infoDictionary ?? [:]
    private var version: String {
        let release = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return "Version \(release) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 44)).foregroundStyle(.white)
                .frame(width: 88, height: 88).background(.blue.gradient, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text("KPasskey").font(.title.bold())
            Text("Kerberos authentication with security keys")
                .foregroundStyle(.secondary)
            Text(version)
                .foregroundStyle(.secondary)
            Button("Licenses") { openWindow(id: "licenses") }
        }
        .padding(32)
        .frame(width: 360)
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(bundledLicenses).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Open Source Licenses")
    }
}
