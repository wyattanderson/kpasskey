import Darwin
import Foundation
import KPasskeyContract
import KPasskeyWorker

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  let requirement: String
  let hostExecutable: String
  init(requirement: String, hostExecutable: String) {
    self.requirement = requirement
    self.hostExecutable = hostExecutable
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    guard connection.effectiveUserIdentifier == geteuid() else { return false }
    #if DEVELOPMENT_PEERS
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(connection.processIdentifier, &path, UInt32(path.count)) > 0,
        path.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == hostExecutable
      else { return false }
    #endif
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
    let identifier = switch Bundle.main.bundleIdentifier {
    case workerIdentifier: hostIdentifier
    case applicationWorkerIdentifier: applicationIdentifier
    default: throw PeerPolicyError.invalidIdentity
    }
    let delegate = try ListenerDelegate(
      requirement: PeerPolicy.requirement(identifier: identifier),
      hostExecutable: host.appendingPathComponent("Contents/MacOS/" +
        (identifier == hostIdentifier ? "KPasskeyHarness" : "KPasskey")).path)
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) { listener.resume() }
  }
}
