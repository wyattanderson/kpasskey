// The menu bar app's related SwiftUI screens live together; splitting solely for line count adds indirection.
// swiftlint:disable file_length
import AppKit
import Foundation
import KPasskeyCache
import KPasskeyClient
import KPasskeyContract
import Observation
import SwiftUI

@main
@MainActor
struct KPasskeyMain {
    static func main() {
        // A read-only bundle diagnostic also exercises peer identity after relocation.
        if CommandLine.arguments.contains("--check-worker") {
            Task { @MainActor in
                let client = WorkerClient()
                do {
                    try await client.connect()
                    print("Connected to embedded worker in a separate process: \(client.workerPID != getpid())")
                    let devices = try await client.devices()
                    print("Device inventory available: \(devices.allSatisfy(\.valid))")
                    _ = try TicketCache.read()
                    print("Shared cache available: true")
                    client.disconnect()
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Could not connect to the embedded worker.\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        KPasskeyApp.main()
    }
}

@MainActor
struct KPasskeyApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var authentication = Authentication()
    @State private var preferences = Preferences()
    @State private var tickets = TicketMonitor()
    @State private var menuBar: AppMenu?

    var body: some Scene {
        Window("Sign In — KPasskey", id: "authentication") {
            AuthenticationView(
                authentication: authentication,
                preferences: preferences,
                tickets: tickets,
                menuBar: $menuBar
            )
            .onDisappear {
                authentication.clearStatus()
                Task { await authentication.cancel() }
            }
        }
        .defaultSize(width: 560, height: 560)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About KPasskey") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit KPasskey") { authentication.disconnect(); NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        Window("About KPasskey", id: "about") {
            AboutView()
        }
        .defaultSize(width: 360, height: 260)
        .windowResizability(.contentSize)
        Window("Licenses", id: "licenses") {
            LicensesView()
        }
        .defaultSize(width: 700, height: 560)
        Settings {
            PreferencesView(preferences: preferences, authentication: authentication)
        }
    }
}

private final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

@MainActor
private final class AppMenu: NSObject, NSMenuDelegate {
    let authentication: Authentication
    let tickets: TicketMonitor
    let status = TicketStatusItem()
    let showSignIn: () -> Void
    let showSettings: () -> Void
    let showAbout: () -> Void

    init(authentication: Authentication, tickets: TicketMonitor,
         showSignIn: @escaping () -> Void, showSettings: @escaping () -> Void,
         showAbout: @escaping () -> Void) {
        self.authentication = authentication
        self.tickets = tickets
        self.showSignIn = showSignIn
        self.showSettings = showSettings
        self.showAbout = showAbout
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        status.item.menu = menu
        observeTickets()
    }

    private func observeTickets() {
        withObservationTracking {
            status.update(state: tickets.state, summary: tickets.summary)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTickets() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        tickets.updateTime()
        menu.removeAllItems()
        for item in ticketMenuItems(tickets.tickets, state: tickets.state, summary: tickets.summary, at: tickets.now) {
            menu.addItem(item)
        }
        let refresh = menu.addItem(withTitle: "Refresh Tickets", action: #selector(refresh), keyEquivalent: "")
        if hasRefreshableTickets(tickets.tickets, at: tickets.now) {
            refresh.target = self
        }
        menu.addItem(
            withTitle: authentication.isRunning ? "Show Sign-In…" : "Sign In…",
            action: #selector(signIn),
            keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: "Settings", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About KPasskey", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit KPasskey", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func refresh() {
        tickets.refresh()
    }

    @objc private func signIn() {
        showSignIn(); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settings() {
        showSettings(); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func about() {
        showAbout(); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        authentication.disconnect(); NSApp.terminate(nil)
    }
}

private struct AuthenticationView: View {
    @Bindable var authentication: Authentication
    @Bindable var preferences: Preferences
    let tickets: TicketMonitor
    @Binding var menuBar: AppMenu?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = false

    private var shouldWatchDevices: Bool {
        windowVisible && preferences.configuration.mode == .passkey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 32)).foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                Text(preferences.configuration.effectiveRealm.isEmpty
                    ? "Sign in to your realm" : "Sign in to realm \(preferences.configuration.effectiveRealm)")
                    .font(.title2.bold())
            }
            HStack {
                Text("Principal")
                Spacer()
                Text(preferences.configuration.principal.isEmpty
                    ? "Set your account in Settings" : preferences.configuration.principal)
                    .foregroundStyle(.secondary).textSelection(.enabled)
                SettingsLink { Text("Settings") }.buttonStyle(.bordered)
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if preferences.configuration.mode == .passkey {
                Text("Available Security Keys").font(.headline).padding(.leading, 16)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(authentication.devices) { device in
                            if device.id != authentication.devices.first?.id {
                                Divider().padding(.horizontal, 12)
                            }
                            Button {
                                authentication.selectedDevice = device.id
                            } label: {
                                HStack(spacing: 12) {
                                    if let icon = device.icon,
                                       let url = Bundle.main.url(
                                           forResource: icon,
                                           withExtension: "png",
                                           subdirectory: "icons"
                                       ),
                                       let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(width: 28, height: 36).accessibilityHidden(true)
                                    } else {
                                        Image(systemName: "key").frame(width: 28, height: 36).accessibilityHidden(true)
                                    }
                                    Text(device.name).font(.title3).multilineTextAlignment(.leading).lineLimit(2)
                                    Spacer()
                                    Image(systemName: authentication.selectedDevice == device.id
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(authentication.selectedDevice == device.id ? Color
                                            .accentColor : .secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(authentication.isRunning)
                            .accessibilityAddTraits(authentication.selectedDevice == device.id ? .isSelected : [])
                            .help(device.name)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(height: CGFloat(min(authentication.devices.count, 4) * 49))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: authentication.devices)
                if !authentication.deviceNotice.isEmpty {
                    Text(authentication.deviceNotice).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 12) {
                if authentication.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(authentication.message).textSelection(.enabled)
                    .accessibilityLabel("Sign-in status: \(authentication.message)")
                Spacer()
                if authentication.isRunning {
                    Button("Cancel", role: .cancel) { Task { await authentication.cancel() } }
                        .keyboardShortcut(.cancelAction)
                        .disabled(authentication.cancelling)
                } else {
                    Button("Sign In") {
                        guard preferences.validate() else { return }
                        Task { await authentication.start(preferences.configuration) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(preferences.configuration.mode == .passkey
                        && !authentication.devices.contains { $0.id == authentication.selectedDevice })
                }
            }.padding(.horizontal, 16)
            if let prompt = authentication.prompt {
                InteractionView(authentication: authentication, prompt: prompt)
                    .id(prompt.interaction)
            }
            if !preferences.notice.isEmpty, !authentication.isRunning {
                Text(preferences.notice).font(.callout).foregroundStyle(.secondary)
            }
            Divider().padding(.horizontal, 16)
            TicketView(tickets: tickets)
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowVisibility { windowVisible = $0 })
        .onAppear {
            if menuBar == nil {
                menuBar = AppMenu(authentication: authentication, tickets: tickets,
                                  showSignIn: { openWindow(id: "authentication") }, showSettings: { openSettings() },
                                  showAbout: { openWindow(id: "about") })
            }
        }
        .onDisappear { windowVisible = false }
        .task(id: shouldWatchDevices) {
            if shouldWatchDevices {
                await authentication.watchDevices()
            }
        }
        .onChange(of: authentication.ticket?.cache) { _, _ in tickets.refresh() }
        .onChange(of: tickets.tickets) { _, tickets in
            authentication.clearPublishedStatus(unless: Set(tickets.map(\.cache)))
        }
    }
}

private struct InteractionView: View {
    let authentication: Authentication
    let prompt: Message
    @State private var secret = ""
    @State private var device = 0
    @FocusState private var secretFocused: Bool

    private var canSubmit: Bool {
        prompt.value == "selectDevice" || Authentication.validSecret(Data(secret.utf8), for: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if prompt.value == "selectDevice" {
                Picker("Security key", selection: $device) {
                    ForEach(prompt.choices.indices, id: \.self) { index in
                        Text(prompt.choices[index]).tag(index)
                    }
                }
            } else {
                SecureField(Authentication.promptLabel(prompt), text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .focused($secretFocused)
                    .onSubmit {
                        if canSubmit {
                            submit()
                        }
                    }
            }
            HStack {
                if let deadline = authentication.promptDeadline {
                    Text("Time remaining:").foregroundStyle(.secondary)
                    Text(timerInterval: Date() ... max(Date(), deadline), countsDown: true)
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || authentication.sending || authentication.cancelling)
            }
        }
        .onAppear { secretFocused = true }
        .onDisappear { secret = "" }
    }

    private func submit() {
        guard canSubmit else { return }
        let bytes = prompt.value == "selectDevice" ? nil : Data(secret.utf8)
        secret = ""
        Task { await authentication.respond(to: prompt, secret: bytes, device: device) }
    }
}

private struct TicketView: View {
    let tickets: TicketMonitor
    @State private var destroyingAll = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cached Tickets").font(.headline).padding(.leading, 16)
            if tickets.error != nil || tickets.tickets.isEmpty {
                Text(tickets.summary).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(tickets.tickets) { ticket in
                            if ticket.id != tickets.tickets.first?.id {
                                Divider().padding(.horizontal, 12)
                            }
                            TicketRow(ticket: ticket, tickets: tickets).disabled(destroyingAll)
                        }
                    }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(height: min(CGFloat(tickets.tickets.count) * 53, 159))
            }
            HStack {
                Spacer()
                Button("Destroy All", role: .destructive) {
                    destroyingAll = true
                    let snapshot = tickets.tickets
                    Task {
                        let failures = await Task.detached(priority: .userInitiated) {
                            TicketCache.destroyAll(snapshot)
                        }.value
                        destroyingAll = false
                        if !failures.isEmpty {
                            failure = "Couldn’t destroy \(failures.count) cache(s). They may have changed or become "
                                + "unavailable. Refresh and try again."
                        }
                        tickets.refresh()
                    }
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(destroyingAll || tickets.loading || tickets.error != nil || tickets.tickets.isEmpty)
                .help("Destroy all listed caches and their tickets")
            }.padding(.top, 8).padding(.horizontal, 16)
        }
        .alert("Couldn’t destroy all caches", isPresented: Binding(
            get: { failure != nil }, set: {
                if !$0 {
                    failure = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

private struct TicketRow: View {
    let ticket: CachedTicket
    let tickets: TicketMonitor
    @State private var hovering = false
    @State private var showingDetails = false
    @State private var destroying = false
    @State private var failure: String?
    @FocusState private var destroyFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ticket.method.symbolName)
                .font(.title2).frame(width: 30).foregroundStyle(.secondary)
                .accessibilityLabel(ticket.method.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.principal).font(.title3).lineLimit(1).truncationMode(.middle)
                Text("Expires \(ticket.expires.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
            }.help("\(ticket.principal) — \(ticket.state(at: tickets.now).rawValue)")
            Spacer(minLength: 0)
            Button("Destroy", role: .destructive) { destroy() }
                .focused($destroyFocused)
                .opacity(hovering || destroyFocused || destroying ? 1 : 0)
                .disabled(destroying)
                .help("Destroy this cache and all its tickets")
            HStack(spacing: 4) {
                if ticket.renewable {
                    Image(systemName: "r.circle").help("Renewable").accessibilityLabel("Renewable")
                }
                if ticket.forwardable {
                    Image(systemName: "f.circle").help("Forwardable").accessibilityLabel("Forwardable")
                }
            }.foregroundStyle(.secondary)
            Button { showingDetails = true } label: {
                Image(systemName: "info.circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details for \(ticket.principal)")
            .popover(isPresented: $showingDetails) {
                TicketDetails(ticket: ticket, destroying: destroying, destroy: destroy)
            }
        }
        .padding(.horizontal, 12).frame(height: 52)
        .contentShape(Rectangle()).onHover { hovering = $0 }
        .alert("Couldn’t destroy cache", isPresented: Binding(
            get: { failure != nil }, set: {
                if !$0 {
                    failure = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func destroy() {
        guard !destroying else { return }
        destroying = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TicketCache.destroy(ticket) }
            }.value
            destroying = false
            switch result {
            case .success: showingDetails = false
            case .failure: failure = "The cache may have changed or become unavailable. Refresh and try again."
            }
            tickets.refresh()
        }
    }
}

private struct TicketDetails: View {
    let ticket: CachedTicket
    let destroying: Bool
    let destroy: () -> Void
    @State private var details = "Reading ticket details…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ticket.principal).font(.headline).textSelection(.enabled)
            ScrollView([.horizontal, .vertical]) {
                Text(details).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }.defaultScrollAnchor(.topLeading)
            Text("Authentication: \(ticket.method.rawValue). This is cache metadata, not a KDC assertion.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Destroy removes this cache and all its tickets.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Destroy", role: .destructive, action: destroy).disabled(destroying)
            }
        }
        .padding(20).frame(width: 600, height: 420)
        .task(id: ticket.id) {
            let result = await Task.detached(priority: .utility) {
                Result { try TicketCache.verboseDetails(cache: ticket.cache) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(text): details = text
            case .failure: details = "Couldn’t read details. The cache may have been removed."
            }
        }
    }
}

private struct PreferencesView: View {
    @Bindable var preferences: Preferences
    let authentication: Authentication

    var body: some View {
        Form {
            Section("Account") {
                TextField("Account", text: $preferences.configuration.principal, prompt: Text("user@REALM"))
                TextField("Realm", text: $preferences.configuration.realm,
                          prompt: Text(preferences.configuration.effectiveRealm.isEmpty
                              ? "From account if included" : preferences.configuration.effectiveRealm))
                TextField("Discovery domain", text: $preferences.configuration.discoveryDomain,
                          prompt: Text("Optional DNS realm discovery"))
                Picker("Sign in with", selection: $preferences.configuration.mode) {
                    Text("USB security key").tag(Configuration.Mode.passkey)
                    Text("Password").tag(Configuration.Mode.password)
                }
                .onChange(of: preferences.configuration.mode) { _, mode in
                    if mode == .password {
                        preferences.configuration.pkinitCA = Data()
                    } else {
                        preferences.configuration.canonicalize = false
                    }
                }
            }
            if preferences.configuration.mode == .passkey {
                Section("Security key") {
                    LabeledContent("KDC CA certificate") {
                        Text(preferences.configuration.pkinitCA.isEmpty ? "Not selected" : "Selected")
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFile { preferences.importCertificate(from: $0) } }
                    }
                    Text(
                        "Use your administrator’s CA certificate. Its subject Organization (O) "
                            + "must exactly match the realm."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Tickets") {
                Toggle("Request forwardable tickets", isOn: $preferences.configuration.forwardable)
                Toggle("Make new ticket the default", isOn: $preferences.configuration.makeDefault)
            }
            Section {
                if !preferences.configuration.kdcs.isEmpty {
                    LabeledContent("KDCs", value: preferences.configuration.kdcs.map(\.address).joined(separator: ", "))
                }
                Button("Import Settings…") { chooseFile { preferences.importSettings(from: $0) } }
                Text(
                    "DNS discovers KDCs by default. Import a KPasskey settings plist for explicit servers "
                        + "and advanced ticket options."
                )
                .font(.caption).foregroundStyle(.secondary)
                if !preferences.notice.isEmpty {
                    Text(preferences.notice).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(authentication.isRunning)
        .safeAreaInset(edge: .bottom) {
            if authentication.isRunning {
                Text("Finish or cancel sign-in before changing settings.").padding()
            }
        }
        .frame(width: 540, height: 590)
    }

    private func chooseFile(_ selected: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selected(url)
        }
    }
}
