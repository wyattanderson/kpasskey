import CMITKerberos
import Foundation
import KPasskeyContract
import KPasskeyWorker
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["KPASSKEY_TEST_DNS_DOMAIN"] != nil))
func optInDNSRealmDiscovery() throws {
  var settings = Configuration(principal: "synthetic")
  settings.discoveryDomain = try #require(ProcessInfo.processInfo.environment["KPASSKEY_TEST_DNS_DOMAIN"])
  let expected = try #require(ProcessInfo.processInfo.environment["KPASSKEY_TEST_DNS_REALM"])
  let context = try makeContext(settings)
  defer { krb5_free_context(context) }
  let principal = try resolvePrincipal(settings, context: context)
  defer { krb5_free_principal(context, principal) }
  let realm = principal.pointee.realm
  #expect(String(decoding: UnsafeRawBufferPointer(start: realm.data, count: Int(realm.length)),
                 as: UTF8.self) == expected)
}

@Test func typedSettingsAndSecretArchives() throws {
  let minimal = Data("""
    <?xml version="1.0"?><plist version="1.0"><dict>
    <key>principal</key><string>user@EXAMPLE.INVALID</string>
    <key>forwardable</key><false/>
    </dict></plist>
    """.utf8)
  let settings = try Configuration.load(minimal)
  #expect(settings.valid && !settings.forwardable && settings.dnsDiscovery)
  #expect(Configuration(principal: "user").forwardable)
  var invalid = settings
  invalid.realm = "OTHER.INVALID"
  #expect(!invalid.valid)
  invalid = settings
  invalid.kdcs = [KDCEndpoint(host: "bad\nhost")]
  #expect(!invalid.valid)
  invalid = settings
  invalid.schema = 2
  #expect(!invalid.valid)
  #expect(!Configuration(principal: "user@REALM@OTHER").valid)
  let start = Message("start", operation: UUID().uuidString, snapshot: Snapshot(configuration: settings))
  let archive = try NSKeyedArchiver.archivedData(withRootObject: start, requiringSecureCoding: true)
  let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: archive))
  #expect(decoded.validCommand && decoded.snapshot?.configuration?.forwardable == false)
  let response = Message("respond", operation: UUID().uuidString,
    interaction: UUID().uuidString, secret: Data("synthetic-only".utf8))
  let bytes = try NSKeyedArchiver.archivedData(withRootObject: response, requiringSecureCoding: true)
  #expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: bytes)?.validCommand == true)
  #expect(!Message("respond", operation: response.operation, interaction: response.interaction,
    secret: Data([0])).validCommand)
  #expect(!Message("cancel", operation: response.operation, secret: Data([1])).validCommand)
}

private func values(_ profile: profile_t, _ path: [String]) throws -> [String] {
  let strings = path.map { strdup($0)! }
  defer { strings.forEach { free($0) } }
  var names = strings.map { Optional(UnsafePointer($0)) } + [nil]
  var output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
  let code = profile_get_values(profile, &names, &output)
  if code == PROF_NO_RELATION || code == PROF_NO_SECTION { return [] }
  #expect(code == 0)
  defer { profile_free_list(output) }
  var result: [String] = []
  var index = 0
  while let value = output?[index] {
    result.append(String(cString: value))
    index += 1
  }
  return result
}

@Test func profileCopyLookupIterationAndExplicitOptions() throws {
  let conflictingFile = try #require(ProcessInfo.processInfo.environment["KRB5_CONFIG"])
  #expect(try String(contentsOfFile: conflictingFile, encoding: .utf8).contains("CONFLICT.INVALID"))
  for realm in ["FIRST.INVALID", "SECOND.INVALID"] {
    var settings = Configuration(principal: "user@" + realm)
    settings.kdcs = [KDCEndpoint(host: "127.0.0.1", port: 9),
                     KDCEndpoint(host: "127.0.0.2", port: 88)]
    settings.forwardable = realm == "FIRST.INVALID"
    let profile = try makeProfile(settings)
    var context: krb5_context?
    #expect(krb5_init_context_profile(profile, KRB5_INIT_CONTEXT_SECURE, &context) == 0)
    profile_abandon(profile)
    let ctx = try #require(context)
    defer { krb5_free_context(ctx) }
    var copy: profile_t?
    #expect(krb5_get_profile(ctx, &copy) == 0)
    let copied = try #require(copy)
    defer { profile_abandon(copied) }
    #expect(try values(copied, ["libdefaults", "default_realm"]) == [realm])
    #expect(try values(copied, ["realms", realm, "kdc"]) == ["127.0.0.1:9", "127.0.0.2:88"])
    #expect(try values(copied, ["libdefaults", "dns_lookup_kdc"]) == ["false"])
    #expect(try values(copied, ["libdefaults", "dns_lookup_realm"]) == ["true"])
    #expect(try values(copied, ["libdefaults", "missing"]).isEmpty)
    #expect(try values(copied, ["plugins", "clpreauth", "enable_only"]) == ["encrypted_timestamp"])
    var iterator: UnsafeMutableRawPointer?
    let strings = [strdup("plugins")!]
    defer { strings.forEach { free($0) } }
    var names: [UnsafePointer<CChar>?] = [UnsafePointer(strings[0]), nil]
    #expect(profile_iterator_create(copied, &names, Int32(PROFILE_ITER_LIST_SECTION | PROFILE_ITER_SECTIONS_ONLY), &iterator) == 0)
    defer { profile_iterator_free(&iterator) }
    var sections = Set<String>()
    while true {
      var name: UnsafeMutablePointer<CChar>?
      var value: UnsafeMutablePointer<CChar>?
      #expect(profile_iterator(&iterator, &name, &value) == 0)
      guard let name else { break }
      sections.insert(String(cString: name))
      profile_release_string(name)
      if let value { profile_release_string(value) }
    }
    #expect(sections == ["clpreauth", "hostrealm"])
    let options = try credentialOptions(settings, context: ctx)
    defer { krb5_get_init_creds_opt_free(ctx, options) }
    #expect(options.pointee.forwardable == (settings.forwardable ? 1 : 0))
    #expect(options.pointee.tkt_life == settings.lifetimeSeconds)
    #expect(options.pointee.renew_life == settings.renewableLifetimeSeconds)
    let principal = try resolvePrincipal(settings, context: ctx)
    defer { krb5_free_principal(ctx, principal) }
    let data = principal.pointee.realm
    #expect(String(decoding: UnsafeRawBufferPointer(start: data.data, count: Int(data.length)), as: UTF8.self) == realm)
  }
}

@Test func cancellationAndCommitHaveOneWinner() throws {
  let cancelled = PublicationGate()
  #expect(cancelled.cancel())
  #expect(throws: KerberosFailure.self) { try cancelled.beginPublication() }
  let committed = PublicationGate()
  try committed.beginPublication()
  #expect(!committed.cancel())
  try committed.check()
  let expired = PublicationGate(deadline: .now.advanced(by: .seconds(-1)))
  #expect(throws: KerberosFailure.self) { try expired.beginPublication() }
  #expect(authenticationStatus(Int32(KRB5KDC_ERR_PREAUTH_FAILED)) == .credentialsRejected)
  #expect(authenticationStatus(Int32(KRB5_KDC_UNREACH)) == .kdcUnavailable)
  #expect(authenticationStatus(Int32(KRB5_CONFIG_NODEFREALM)) == .configurationInvalid)
  #expect(authenticationStatus(Int32(KRB5_LIBOS_CANTREADPWD)) == .unexpectedPrompt)
  #expect(authenticationStatus(Int32(KRB5_PREAUTH_FAILED)) == .authenticationFailed)
}

@Test func publicationFailureRollsBackOnlyItsOwnCache() throws {
  let settings = Configuration(principal: "user@EXAMPLE.INVALID")
  let context = try makeContext(settings)
  defer { krb5_free_context(context) }
  #expect(String(cString: krb5_cc_default_name(context)).hasPrefix("MEMORY:"))
  let principal = try resolvePrincipal(settings, context: context)
  defer { krb5_free_principal(context, principal) }
  var unrelated: krb5_ccache?
  var staging: krb5_ccache?
  #expect(krb5_cc_new_unique(context, "MEMORY", nil, &unrelated) == 0)
  #expect(krb5_cc_new_unique(context, "MEMORY", nil, &staging) == 0)
  defer {
    krb5_cc_destroy(context, staging)
    krb5_cc_destroy(context, unrelated)
  }
  #expect(krb5_cc_initialize(context, unrelated, principal) == 0)
  #expect(krb5_cc_initialize(context, staging, principal) == 0)
  var credentials = krb5_creds()
  credentials.client = principal
  credentials.times.endtime = Int32(Date().timeIntervalSince1970) + 3600
  var createdName = ""
  do {
    _ = try publish(context: context, staging: staging!, credentials: &credentials,
      makeDefault: false, gate: PublicationGate(), createCache: { context, output in
        // Exercise rollback with real MIT cache handles without touching the user's API collection.
        let code = krb5_cc_new_unique(context, "MEMORY", nil, output)
        if code == 0 { createdName = "MEMORY:" + String(cString: krb5_cc_get_name(context, output.pointee)) }
        return code
      })
    Issue.record("Non-API publication must fail")
  } catch let error as KerberosFailure { #expect(error.status == .publicationFailed) }
  var retainedPrincipal: krb5_principal?
  #expect(krb5_cc_get_principal(context, unrelated, &retainedPrincipal) == 0)
  #expect(krb5_principal_compare(context, retainedPrincipal, principal) != 0)
  krb5_free_principal(context, retainedPrincipal)
  var rolledBack: krb5_ccache?
  #expect(!createdName.isEmpty)
  #expect(krb5_cc_resolve(context, createdName, &rolledBack) == 0)
  defer { krb5_cc_destroy(context, rolledBack) }
  var missing: krb5_principal?
  #expect(krb5_cc_get_principal(context, rolledBack, &missing) != 0)
  if let missing { krb5_free_principal(context, missing) }
}

@Test func unavailableKDCNeverPublishes() throws {
  var settings = Configuration(principal: "synthetic@EXAMPLE.INVALID")
  settings.dnsDiscovery = false
  settings.kdcs = [KDCEndpoint(host: "127.0.0.1", port: 1)]
  settings.networkTimeoutSeconds = 1
  do {
    _ = try acquirePassword(settings, password: Data("synthetic-only".utf8), gate: PublicationGate())
    Issue.record("Unexpected authentication success")
  } catch let error as KerberosFailure {
    #expect(error.status == .kdcUnavailable)
  }
}

@Test func rejectedPasswordFromSyntheticKDC() throws {
  // A minimal RFC 4120 KRB-ERROR fixture exercises MIT's real decoder and worker mapping.
  func der(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
    [tag] + (contents.count < 128 ? [UInt8(contents.count)] : [0x81, UInt8(contents.count)]) + contents
  }
  let realm = Array("EXAMPLE.INVALID".utf8)
  let packet = der(0x7e, der(0x30,
    der(0xa0, der(0x02, [5])) + der(0xa1, der(0x02, [30]))
      + der(0xa4, der(0x18, Array("20260101000000Z".utf8))) + der(0xa5, der(0x02, [0]))
      + der(0xa6, der(0x02, [24])) + der(0xa9, der(0x1b, realm))
      + der(0xaa, der(0x30, der(0xa0, der(0x02, [2]))
        + der(0xa1, der(0x30, der(0x1b, Array("krbtgt".utf8)) + der(0x1b, realm)))))))
  let server = socket(AF_INET, SOCK_DGRAM, 0)
  defer { close(server) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
  try withUnsafePointer(to: &address) { pointer in
    let code = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    try #require(code == 0)
  }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  withUnsafeMutablePointer(to: &address) { pointer in
    _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
  }
  var timeout = timeval(tv_sec: 3, tv_usec: 0)
  #expect(setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    defer { finished.signal() }
    var request = [UInt8](repeating: 0, count: 4096)
    var peer = sockaddr_storage()
    var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
    // MIT restarts once after PREAUTH_FAILED to retry without informational preauthentication data.
    for _ in 0..<2 {
      withUnsafeMutablePointer(to: &peer) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { remote in
          if recvfrom(server, &request, request.count, 0, remote, &size) > 0 {
            _ = packet.withUnsafeBytes { sendto(server, $0.baseAddress, $0.count, 0, remote, size) }
          }
        }
      }
    }
  }
  defer { _ = finished.wait(timeout: .now() + 4) }
  var settings = Configuration(principal: "synthetic@EXAMPLE.INVALID")
  settings.dnsDiscovery = false
  settings.transport = .udpFirst
  settings.kdcs = [KDCEndpoint(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)))]
  settings.networkTimeoutSeconds = 1
  do {
    _ = try acquirePassword(settings, password: Data("synthetic-only".utf8), gate: PublicationGate())
    Issue.record("KDC rejection must not publish credentials")
  } catch let error as KerberosFailure { #expect(error.status == .credentialsRejected) }
}

@Test @MainActor func passwordInteractionCancellationAndExpiry() async throws {
  for cancel in [true, false] {
    var events: [Message] = []
    let session = WorkerSession { events.append($0) }
    _ = session.handle(Message("negotiate"))
    var settings = Configuration(principal: "user@EXAMPLE.INVALID")
    settings.timeoutMilliseconds = 200
    let id = UUID().uuidString
    #expect(session.handle(Message("start", operation: id, snapshot: Snapshot(configuration: settings))).value == "ok")
    let prompt = try #require(events.last)
    #expect(prompt.value == "password")
    #expect(session.handle(Message("respond", operation: id, interaction: prompt.interaction,
      value: "continue")).value == "protocolViolation")
    if cancel { _ = session.handle(Message("cancel", operation: id)) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(events.filter { $0.kind == "terminal" }.map(\.value) == [cancel ? "cancelled" : "deadlineExceeded"])
    #expect(events.allSatisfy { $0.ticket == nil && $0.secret == nil })
    #expect(session.handle(Message("respond", operation: id, interaction: prompt.interaction,
      secret: Data("synthetic-only".utf8))).value == "staleInteraction")
  }
}
