import CMITKerberos
import Foundation

/// Read-only presentation metadata. Authentication methods are cache hints, not KDC assertions.
public struct CachedTicket: Equatable, Identifiable, Sendable {
  public enum Method: String, Sendable {
    case password = "Password", passkey = "Passkey", unknown = "Authentication method unreported"
  }
  public enum State: String, Sendable {
    case none = "No tickets", password = "Valid ticket", passkey = "Valid passkey ticket"
    case expiring = "Ticket expires in less than 15 minutes", expired = "Expired ticket"
    case unavailable = "Ticket unavailable"
  }
  public let cache: String
  public let principal: String
  public let starts: Date
  public let expires: Date
  public let invalid: Bool
  public let renewable: Bool
  public let forwardable: Bool
  public let method: Method
  public var id: String { cache + "|" + principal }

  public init(cache: String, principal: String, starts: Date, expires: Date,
              invalid: Bool = false, method: Method,
              renewable: Bool = false, forwardable: Bool = false) {
    self.cache = cache
    self.principal = principal
    self.starts = starts
    self.expires = expires
    self.invalid = invalid
    self.method = method
    self.renewable = renewable
    self.forwardable = forwardable
  }

  public func state(at now: Date) -> State {
    if expires <= now { return .expired }
    if invalid || starts > now { return .unavailable }
    if expires.timeIntervalSince(now) < 900 { return .expiring }
    return method == .passkey ? .passkey : .password
  }

  /// Prefer a usable passkey TGT, then another usable TGT, then the latest expired TGT.
  public static func preferred(in tickets: [Self], at now: Date) -> Self? {
    tickets.sorted {
      let lhs = $0.starts <= now && $0.expires > now && !$0.invalid
      let rhs = $1.starts <= now && $1.expires > now && !$1.invalid
      if lhs != rhs { return lhs }
      if lhs && ($0.method == .passkey) != ($1.method == .passkey) { return $0.method == .passkey }
      if $0.expires != $1.expires { return $0.expires > $1.expires }
      return $0.id < $1.id
    }.first
  }

  public static func nextTransition(in tickets: [Self], after now: Date) -> Date? {
    tickets.flatMap { [$0.starts, $0.expires.addingTimeInterval(-900).addingTimeInterval(0.001), $0.expires] }
      .filter { $0 > now }.min()
  }
}

public struct CacheReadFailure: Error { public let code: Int32 }

/// Handles never leave the calling thread. Reads never change the cache or contact a KDC.
public enum TicketCache {
  private static func check(_ code: Int32) throws {
    if code != 0 { throw CacheReadFailure(code: code) }
  }

  /// Attempt each displayed cache once, returning failures without skipping later caches.
  public static func destroyAll(_ tickets: [CachedTicket]) -> [String] {
    var visited: Set<String> = []
    var failures: [String] = []
    for ticket in tickets where visited.insert(ticket.cache).inserted {
      do { try destroy(ticket) }
      catch { failures.append(ticket.cache) }
    }

    return failures
  }

  /// Destroy only the explicitly selected cache, rejecting a stale presentation snapshot.
  public static func destroy(_ ticket: CachedTicket) throws {
    try validateName(ticket.cache)
    var context: krb5_context?
    try check(krb5_init_secure_context(&context))
    guard let context else { throw CacheReadFailure(code: -1) }
    defer { krb5_free_context(context) }
    var cache: krb5_ccache?
    try check(krb5_cc_resolve(context, ticket.cache, &cache))
    guard let cache else { throw CacheReadFailure(code: -1) }
    var destroying = false
    defer { if !destroying { krb5_cc_close(context, cache) } }
    guard try read(context: context, cache: cache).contains(ticket) else {
      throw CacheReadFailure(code: Int32(KRB5_CC_NOTFOUND))
    }
    destroying = true
    try check(krb5_cc_destroy(context, cache))
    // The upstream macOS backend discards CCAPI's destroy error; verify removal.
    var remaining: krb5_ccache?
    try check(krb5_cc_resolve(context, ticket.cache, &remaining))
    guard let remaining else { throw CacheReadFailure(code: -1) }
    defer { krb5_cc_close(context, remaining) }
    var principal: krb5_principal?
    let code = krb5_cc_get_principal(context, remaining, &principal)
    defer { krb5_free_principal(context, principal) }
    guard code == KRB5_FCC_NOFILE || code == KRB5_CC_NOTFOUND else {
      throw CacheReadFailure(code: code == 0 ? -1 : code)
    }
  }

  /// Use the system's own verbose presentation, including service tickets and cache metadata.
  public static func verboseDetails(cache: String) throws -> String {
    try validateName(cache)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/klist")
    process.arguments = ["--verbose", "--cache=\(cache)"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try check(process.terminationStatus)
    return String(decoding: data, as: UTF8.self)
  }

  private static func validateName(_ name: String) throws {
    // MEMORY caches support isolated tests; never resolve an empty/default or filesystem cache.
    guard let prefix = ["API:", "MEMORY:"].first(where: { name.hasPrefix($0) }),
      name.count > prefix.count, !name.utf8.contains(0) else { throw CacheReadFailure(code: -1) }
  }

  public static func read() throws -> [CachedTicket] {
    var context: krb5_context?
    try check(krb5_init_secure_context(&context))
    guard let context else { throw CacheReadFailure(code: -1) }
    defer { krb5_free_context(context) }
    // Enumerate the shared macOS collection regardless of the app's launch environment.
    try check(krb5_cc_set_default_name(context, "API:"))
    var cursor: krb5_cccol_cursor?
    try check(krb5_cccol_cursor_new(context, &cursor))
    defer { krb5_cccol_cursor_free(context, &cursor) }
    var result: [CachedTicket] = []
    while true {
      var cache: krb5_ccache?
      try check(krb5_cccol_cursor_next(context, cursor, &cache))
      guard let cache else { break }
      defer { krb5_cc_close(context, cache) }
      guard String(cString: krb5_cc_get_type(context, cache)) == "API" else { continue }
      do { result += try read(context: context, cache: cache) }
      catch let error as CacheReadFailure where error.code == KRB5_FCC_NOFILE || error.code == KRB5_CC_NOTFOUND {
        // A cache can disappear between collection enumeration and credential iteration.
        continue
      }
    }
    return result.sorted { $0.id < $1.id }
  }

  public static func read(context: krb5_context, cache: krb5_ccache) throws -> [CachedTicket] {
    var cursor: krb5_cc_cursor?
    try check(krb5_cc_start_seq_get(context, cache, &cursor))
    defer { krb5_cc_end_seq_get(context, cache, &cursor) }
    var name: UnsafeMutablePointer<CChar>?
    try check(krb5_cc_get_full_name(context, cache, &name))
    guard let name else { throw CacheReadFailure(code: -1) }
    defer { krb5_free_string(context, name) }
    let cacheName = String(cString: name)
    var result: [CachedTicket] = []
    while true {
      var credentials = krb5_creds()
      let code = krb5_cc_next_cred(context, cache, &cursor, &credentials)
      if code == KRB5_CC_END { break }
      try check(code)
      defer { krb5_free_cred_contents(context, &credentials) }
      guard let server = credentials.server, let client = credentials.client,
        server.pointee.length == 2, let components = server.pointee.data,
        string(components[0]) == "krbtgt",
        string(components[1]) == string(client.pointee.realm),
        string(server.pointee.realm) == string(client.pointee.realm) else { continue }
      var principal: UnsafeMutablePointer<CChar>?
      try check(krb5_unparse_name(context, client, &principal))
      guard let principal else { throw CacheReadFailure(code: -1) }
      defer { krb5_free_unparsed_name(context, principal) }
      var data = krb5_data()
      let configCode = krb5_cc_get_config(context, cache, server, "pa_type", &data)
      defer { krb5_free_data_contents(context, &data) }
      if configCode != 0 && configCode != KRB5_CC_NOTFOUND { try check(configCode) }
      // MIT saves the selected preauthentication type with the TGT. Heimdal may omit it.
      let method: CachedTicket.Method = switch configCode == 0 ? string(data) : "" {
      case "153": .passkey
      case "2", "138": .password
      default: .unknown
      }
      let start = credentials.times.starttime == 0 ? credentials.times.authtime : credentials.times.starttime
      result.append(CachedTicket(cache: cacheName, principal: String(cString: principal),
        starts: Date(timeIntervalSince1970: Double(start)),
        expires: Date(timeIntervalSince1970: Double(credentials.times.endtime)),
        invalid: credentials.ticket_flags & TKT_FLG_INVALID != 0, method: method,
        renewable: credentials.ticket_flags & TKT_FLG_RENEWABLE != 0,
        forwardable: credentials.ticket_flags & TKT_FLG_FORWARDABLE != 0))
    }
    return Dictionary(grouping: result, by: \.id).values.compactMap {
      $0.max { $0.expires < $1.expires }
    }.sorted { $0.id < $1.id }
  }

  private static func string(_ data: krb5_data) -> String {
    String(decoding: UnsafeRawBufferPointer(start: data.data, count: Int(data.length)), as: UTF8.self)
  }
}
