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
      let session = WorkerSession(terminateBlockedWorker: { _exit(0) }) { [weak connection] event in
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
    // Sanitize once before threads or dependent libraries run; never mutate per operation.
    for key in ["KRB5_CONFIG", "KRB5_KDC_PROFILE", "KRB5CCNAME", "KRB5_TRACE", "KRB5_KTNAME",
                "KRB5_CLIENT_KTNAME", "OPENSSL_CONF", "OPENSSL_CONF_INCLUDE", "OPENSSL_MODULES",
                "OPENSSL_ENGINES", "RANDFILE", "LOCALDOMAIN", "RES_OPTIONS", "HOSTALIASES"] {
      unsetenv(key)
    }
    // Worker.xpc is always nested directly in its owning application's XPCServices directory.
    let host = Bundle.main.bundleURL.deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    guard let identifier = Bundle(url: host)?.bundleIdentifier,
      [hostIdentifier, applicationIdentifier].contains(identifier)
    else { throw PeerPolicyError.invalidIdentity }
    let delegate = try ListenerDelegate(
      requirement: PeerPolicy.requirement(peer: host, identifier: identifier))
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) { listener.resume() }
  }
}
