import AppKit
import Foundation
import KPasskeyClient
import KPasskeyContract
import KPasskeyCache
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
  @State private var authentication = Authentication()
  @State private var preferences = Preferences()
  @State private var tickets = TicketMonitor()

  var body: some Scene {
    Window("Sign In — KPasskey", id: "authentication") {
      AuthenticationView(authentication: authentication, preferences: preferences, tickets: tickets)
        .onDisappear { Task { await authentication.cancel() } }
    }
    .defaultSize(width: 480, height: 480)
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .appTermination) {
        Button("Quit KPasskey") { authentication.disconnect(); NSApp.terminate(nil) }
          .keyboardShortcut("q")
      }
    }
    MenuBarExtra {
      AppMenu(authentication: authentication, tickets: tickets)
    } label: {
      TicketStatusIcon(state: tickets.state, summary: tickets.summary)
    }
    Settings {
      PreferencesView(preferences: preferences, authentication: authentication)
    }
  }
}

private struct AppMenu: View {
  let authentication: Authentication
  let tickets: TicketMonitor
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(authentication.isRunning ? authentication.message : "KPasskey")
    Text(tickets.summary)
    ForEach(tickets.tickets) { ticket in
      Text("\(ticket.principal) — \(ticket.method.rawValue)")
      Text("\(ticket.state(at: tickets.now).rawValue) · \(ticket.expires.formatted(date: .abbreviated, time: .shortened))")
    }
    Button("Refresh Tickets") { tickets.refresh() }
    Button(authentication.isRunning ? "Show Sign-In…" : "Sign In…") {
      openWindow(id: "authentication")
      NSApp.activate(ignoringOtherApps: true)
    }
    Divider()
    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
      .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
    Divider()
    Button("Quit KPasskey") { authentication.disconnect(); NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }
}

private struct AuthenticationView: View {
  @Bindable var authentication: Authentication
  @Bindable var preferences: Preferences
  let tickets: TicketMonitor
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var windowVisible = false

  private var shouldWatchDevices: Bool { windowVisible && preferences.configuration.mode == .passkey }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 14) {
        Image(systemName: "key.horizontal.fill")
          .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Sign in to your realm").font(.title2.bold())
          Text("Use your account to get a Kerberos ticket.").foregroundStyle(.secondary)
        }
      }
      TextField("Account", text: $preferences.configuration.principal,
                prompt: Text("user@REALM"))
        .textFieldStyle(.roundedBorder)
        .disabled(authentication.isRunning)
      HStack {
        Label(preferences.configuration.mode == .passkey ? "Security keys" : "Password",
              systemImage: preferences.configuration.mode == .passkey ? "key" : "lock")
        Spacer()
        SettingsLink { Text("Settings…") }
      }.foregroundStyle(.secondary)
      if preferences.configuration.mode == .passkey {
        ScrollView {
          VStack(spacing: 8) {
            ForEach(authentication.devices) { device in
              Button {
                authentication.selectedDevice = device.id
              } label: {
                HStack(spacing: 12) {
                  if let icon = device.icon,
                    let url = Bundle.main.url(forResource: icon, withExtension: "png"),
                    let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                      .frame(width: 28, height: 36).accessibilityHidden(true)
                  } else {
                    Image(systemName: "key").frame(width: 28, height: 36).accessibilityHidden(true)
                  }
                  Text(device.name).multilineTextAlignment(.leading).lineLimit(2)
                  Spacer()
                  Image(systemName: authentication.selectedDevice == device.id
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(authentication.selectedDevice == device.id ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                }
                .padding(10)
                .contentShape(Rectangle())
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
              }
              .buttonStyle(.plain)
              .disabled(authentication.isRunning)
              .accessibilityAddTraits(authentication.selectedDevice == device.id ? .isSelected : [])
              .help(device.name)
              .transition(.opacity.combined(with: .move(edge: .top)))
            }
          }
        }
        .frame(height: CGFloat(min(authentication.devices.count, 4) * 64 - (authentication.devices.isEmpty ? 0 : 8)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: authentication.devices)
        if !authentication.deviceNotice.isEmpty {
          Text(authentication.deviceNotice).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Divider()
      HStack(alignment: .top, spacing: 12) {
        if authentication.isRunning { ProgressView().controlSize(.small) }
        Text(authentication.message).textSelection(.enabled)
          .accessibilityLabel("Sign-in status: \(authentication.message)")
      }
      if let prompt = authentication.prompt {
        InteractionView(authentication: authentication, prompt: prompt)
          .id(prompt.interaction)
      }
      if !preferences.notice.isEmpty && !authentication.isRunning {
        Text(preferences.notice).font(.callout).foregroundStyle(.secondary)
      }
      TicketView(tickets: tickets)
      HStack {
        Spacer()
        if authentication.isRunning {
          Button("Cancel", role: .cancel) { Task { await authentication.cancel() } }
            .keyboardShortcut(.cancelAction)
            .disabled(authentication.cancelling)
        } else {
          Button("Sign In") {
            guard preferences.save() else { return }
            Task { await authentication.start(preferences.configuration) }
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(preferences.configuration.mode == .passkey
            && !authentication.devices.contains { $0.id == authentication.selectedDevice })
        }
      }
    }
    .padding(24)
    .frame(width: 480)
    .background(WindowVisibility { windowVisible = $0 })
    .onDisappear { windowVisible = false }
    .task(id: shouldWatchDevices) {
      if shouldWatchDevices { await authentication.watchDevices() }
    }
    .onChange(of: authentication.ticket?.cache) { _, _ in tickets.refresh() }
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
          .onSubmit { if canSubmit { submit() } }
      }
      HStack {
        if let deadline = authentication.promptDeadline {
          Text("Time remaining:").foregroundStyle(.secondary)
          Text(timerInterval: Date()...max(Date(), deadline), countsDown: true)
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

  var body: some View {
    GroupBox("macOS tickets") {
      VStack(alignment: .leading, spacing: 6) {
        Text(tickets.summary).fontWeight(.medium)
        if tickets.error == nil && !tickets.tickets.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(tickets.tickets) { ticket in
                VStack(alignment: .leading, spacing: 4) {
                  Text(ticket.principal).fontWeight(.medium).textSelection(.enabled)
                  Text(ticket.method.rawValue)
                  Text(ticket.state(at: tickets.now).rawValue)
                  Text("Expires \(ticket.expires.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(height: min(CGFloat(tickets.tickets.count) * 100, 160))
          Text("Authentication methods come from cache metadata. KDC authentication indicators are encrypted.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
  }
}

private struct TicketStatusIcon: View {
  let state: CachedTicket.State
  let summary: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // A non-template image preserves the pill's color in MenuBarExtra's label.
    let ink: NSColor = colorScheme == .dark ? .white : .black
    let pill: NSColor? = switch state {
    case .password: .systemYellow
    case .passkey: .systemGreen
    case .expiring: .systemOrange
    case .expired: .systemRed
    case .none, .unavailable: nil
    }
    let symbol = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(paletteColors: [ink]))
    let size = symbol?.size ?? NSSize(width: 18, height: 18)
    let scale = min(18 / size.width, 18 / size.height)
    let width = size.width * scale, height = size.height * scale
    let icon = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
      symbol?.draw(in: NSRect(x: (18 - width) / 2, y: (18 - height) / 2, width: width, height: height))
      if let pill {
        pill.setFill()
        NSBezierPath(ovalIn: NSRect(x: 20, y: 7, width: 4, height: 4)).fill()
      }
      return true
    }
    Image(nsImage: icon).renderingMode(.original).accessibilityLabel("KPasskey: \(summary)")
      .help(summary)
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
          } else { preferences.configuration.canonicalize = false }
        }
      }
      if preferences.configuration.mode == .passkey {
        Section("Security key") {
          LabeledContent("KDC CA certificate") {
            Text(preferences.configuration.pkinitCA.isEmpty ? "Not selected" : "Selected")
              .foregroundStyle(.secondary)
            Button("Choose…") { chooseFile { preferences.importCertificate(from: $0) } }
          }
          Text("Use your administrator’s CA certificate. Its subject Organization (O) must exactly match the realm.")
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
        Text("DNS discovers KDCs by default. Import a KPasskey settings plist for explicit servers and advanced ticket options.")
          .font(.caption).foregroundStyle(.secondary)
        if !preferences.notice.isEmpty { Text(preferences.notice).font(.callout) }
        Button("Save Settings") { preferences.save() }.keyboardShortcut("s")
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
    if panel.runModal() == .OK, let url = panel.url { selected(url) }
  }
}
