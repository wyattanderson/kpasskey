import Foundation
import KPasskeyContract
import KPasskeyWorker

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  let requirement: String
  init(requirement: String) { self.requirement = requirement }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    guard connection.effectiveUserIdentifier == geteuid() else { return false }
    connection.setCodeSigningRequirement(requirement)
    connection.exportedInterface = workerInterface()
    connection.remoteObjectInterface = clientInterface()
    // Transfer the inactive connection to the main actor. This delegate does not
    // touch it again; only NSXPC's own thread-safe transport runs on other queues.
    nonisolated(unsafe) let accepted = connection
    Task { @MainActor in
      let connection = accepted
      let session = FakeSession { [weak connection] event in
        (connection?.remoteObjectProxyWithErrorHandler { @Sendable _ in } as? ClientProtocol)?
          .receive(event)
      }
      connection.exportedObject = session
      let cleanup: @Sendable () -> Void = { [weak session] in
        Task { @MainActor in session?.disconnect() }
      }
      connection.invalidationHandler = cleanup
      connection.interruptionHandler = cleanup
      connection.activate()
    }
    return true
  }
}

@main
struct WorkerMain {
  static func main() throws {
    // Worker.xpc is always nested directly in its owning application's XPCServices directory.
    let host = Bundle.main.bundleURL.deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let delegate = try ListenerDelegate(
      requirement: PeerPolicy.requirement(peer: host, identifier: hostIdentifier))
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) { listener.resume() }
  }
}
