import AppKit
import CNotifications
import KPasskeyCache
import Observation

@MainActor @Observable
final class TicketMonitor {
  private(set) var tickets: [CachedTicket] = []
  private(set) var error: String?
  private(set) var now = Date()
  private(set) var loading = true
  @ObservationIgnored private var token: Int32 = -1
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var transition: Timer?
  @ObservationIgnored private var fallback: Timer?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshAgain = false

  var preferred: CachedTicket? { CachedTicket.preferred(in: tickets, at: now) }
  var state: CachedTicket.State {
    error != nil || loading ? .unavailable : preferred?.state(at: now) ?? .none
  }
  var summary: String { error ?? (loading ? "Reading tickets…" : state.rawValue) }

  init() {
    // Apple's Heimdal cache service posts this Darwin notification, coalesced by the daemon.
    let result = notify_register_dispatch("com.apple.Kerberos.cache.changed", &token, .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    if result != NOTIFY_STATUS_OK { token = -1 }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      })
    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      })
    // A slow safety refresh covers dropped notifications and cache service restarts.
    let interval: TimeInterval = token == -1 ? 60 : 300
    fallback = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    fallback?.tolerance = interval / 5
    RunLoop.main.add(fallback!, forMode: .common)
    refresh()
  }

  func refresh() {
    guard refreshTask == nil else { refreshAgain = true; return }
    refreshTask = Task { [weak self] in
      // Debounce bursts without postponing an in-flight read or spawning parallel scans.
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      self?.refreshAgain = false
      let result = await Task.detached(priority: .utility) { Result { try TicketCache.read() } }.value
      guard let self else { return }
      switch result {
      case .success(let tickets): self.tickets = tickets; self.error = nil
      case .failure:
        self.tickets = []
        self.error = "Couldn’t read the macOS ticket cache."
      }
      self.loading = false
      self.updateTime()
      self.refreshTask = nil
      if self.refreshAgain { self.refreshAgain = false; self.refresh() }
    }
  }

  private func updateTime() {
    now = Date()
    transition?.invalidate()
    guard let next = CachedTicket.nextTransition(in: tickets, after: now) else { return }
    transition = Timer(timeInterval: max(0.001, next.timeIntervalSinceNow), repeats: false) {
      [weak self] _ in Task { @MainActor in self?.updateTime() }
    }
    RunLoop.main.add(transition!, forMode: .common)
  }

  isolated deinit {
    if token != -1 { notify_cancel(token) }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    transition?.invalidate()
    fallback?.invalidate()
    refreshTask?.cancel()
  }
}
