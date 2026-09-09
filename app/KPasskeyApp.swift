import AppKit
import Foundation
import KPasskeyClient
import KPasskeyContract
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

  var body: some Scene {
    Window("Sign In — KPasskey", id: "authentication") {
      AuthenticationView(authentication: authentication, preferences: preferences)
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
    MenuBarExtra("KPasskey", systemImage: "key.horizontal") {
      AppMenu(authentication: authentication)
    }
    Settings {
      PreferencesView(preferences: preferences, authentication: authentication)
    }
  }
}

private struct AppMenu: View {
  let authentication: Authentication
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(authentication.isRunning ? authentication.message : "KPasskey")
    if let ticket = authentication.ticket {
      Text("Last sign-in: \(ticket.principal)")
    }
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
  let authentication: Authentication
  @Bindable var preferences: Preferences

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
        Label(preferences.configuration.mode == .passkey ? "USB security key" : "Password",
              systemImage: preferences.configuration.mode == .passkey ? "key" : "lock")
        Spacer()
        SettingsLink { Text("Settings…") }
      }.foregroundStyle(.secondary)
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
      if let ticket = authentication.ticket {
        TicketView(ticket: ticket)
      }
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
        }
      }
    }
    .padding(24)
    .frame(width: 480)
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
  let ticket: TicketMetadata

  var body: some View {
    GroupBox("Last published ticket") {
      VStack(alignment: .leading, spacing: 6) {
        Text(ticket.principal).fontWeight(.medium).textSelection(.enabled)
        TimelineView(.periodic(from: .now, by: 30)) { context in
          let expiry = Date(timeIntervalSince1970: Double(ticket.expires))
          if expiry <= context.date {
            Label("Expired", systemImage: "clock.badge.exclamationmark")
          } else {
            Text("Expires \(expiry, style: .relative) from now")
          }
        }
        Text("Published during this session. Changes made by other apps aren’t monitored.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
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
        TextField("Realm", text: $preferences.configuration.realm, prompt: Text("From account if included"))
        TextField("Discovery domain", text: $preferences.configuration.discoveryDomain,
                  prompt: Text("Optional DNS realm discovery"))
        Picker("Sign in with", selection: $preferences.configuration.mode) {
          Text("USB security key").tag(Configuration.Mode.passkey)
          Text("Password").tag(Configuration.Mode.password)
        }
        .onChange(of: preferences.configuration.mode) { _, mode in
          if mode == .password {
            preferences.configuration.rpID = ""
            preferences.configuration.pkinitCA = Data()
          } else { preferences.configuration.canonicalize = false }
        }
      }
      if preferences.configuration.mode == .passkey {
        Section("Security key") {
          TextField("Relying party", text: $preferences.configuration.rpID, prompt: Text("example.org"))
          LabeledContent("KDC CA certificate") {
            Text(preferences.configuration.pkinitCA.isEmpty ? "Not selected" : "Selected")
              .foregroundStyle(.secondary)
            Button("Choose…") { chooseFile { preferences.importCertificate(from: $0) } }
          }
          Text("Use the CA certificate supplied by your realm administrator.")
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
