import CMITKerberos
import Foundation
import KPasskeyCache
import Testing

@Test func ticketStatesAndTransitions() {
    let now = Date(timeIntervalSince1970: 10000)
    func ticket(_ seconds: Double, _ method: CachedTicket.Method = .password,
                starts: Double = -100, invalid: Bool = false) -> CachedTicket {
        CachedTicket(cache: "MEMORY:\(seconds)-\(method)", principal: "user@EXAMPLE.INVALID",
                     starts: now.addingTimeInterval(starts), expires: now.addingTimeInterval(seconds),
                     invalid: invalid, method: method)
    }
    #expect(CachedTicket.preferred(in: [], at: now) == nil)
    #expect(ticket(901).state(at: now) == .password)
    #expect(ticket(901, .passkey).state(at: now) == .passkey)
    #expect(ticket(900, .passkey).state(at: now) == .passkey)
    #expect(ticket(899, .passkey).state(at: now) == .expiring)
    #expect(ticket(899).state(at: now) == .expiring)
    #expect(ticket(0).state(at: now) == .expired)
    #expect(ticket(-1, .passkey).state(at: now) == .expired)
    #expect(ticket(901, .unknown).state(at: now) == .password)
    #expect(ticket(901, starts: 10).state(at: now) == .unavailable)
    #expect(ticket(901, invalid: true).state(at: now) == .unavailable)
    #expect(CachedTicket.preferred(in: [ticket(-1, .passkey), ticket(1000)], at: now)?.method == .password)
    #expect(CachedTicket.preferred(in: [ticket(1000), ticket(200, .passkey)], at: now)?.method == .passkey)
    #expect(CachedTicket.preferred(in: [ticket(-10), ticket(-1)], at: now)?.expires == now.addingTimeInterval(-1))
    #expect(CachedTicket.nextTransition(in: [], after: now) == nil)
    #expect(CachedTicket.nextTransition(in: [ticket(899)], after: now) == now.addingTimeInterval(899))
    #expect(CachedTicket.nextTransition(in: [ticket(900)], after: now) == now.addingTimeInterval(0.001))
}

@Test func readsRealCacheWithoutCountingConfigurationOrServiceTickets() throws {
    var context: krb5_context?
    #expect(krb5_init_secure_context(&context) == 0)
    let ctx = try #require(context)
    defer { krb5_free_context(ctx) }
    var cache: krb5_ccache?
    #expect(krb5_cc_new_unique(ctx, "MEMORY", nil, &cache) == 0)
    let cacheHandle = try #require(cache)
    defer { krb5_cc_destroy(ctx, cacheHandle) }
    var client: krb5_principal?
    #expect(krb5_parse_name(ctx, "user@EXAMPLE.INVALID", &client) == 0)
    defer { krb5_free_principal(ctx, client) }
    #expect(krb5_cc_initialize(ctx, cacheHandle, client) == 0)
    #expect(try TicketCache.read(context: ctx, cache: cacheHandle).isEmpty)
    var tgt: krb5_principal?
    #expect(krb5_parse_name(ctx, "krbtgt/EXAMPLE.INVALID@EXAMPLE.INVALID", &tgt) == 0)
    defer { krb5_free_principal(ctx, tgt) }
    var credentials = krb5_creds()
    credentials.client = client
    credentials.server = tgt
    credentials.times.authtime = 1000
    credentials.times.endtime = 2000
    credentials.ticket_flags = TKT_FLG_RENEWABLE | TKT_FLG_FORWARDABLE
    #expect(krb5_cc_store_cred(ctx, cacheHandle, &credentials) == 0)
    for (value, expected) in [("153", CachedTicket.Method.passkey), ("2", .password),
                              ("138", .password), ("16", .unknown), ("bad", .unknown)] {
        #expect(krb5_cc_initialize(ctx, cacheHandle, client) == 0)
        #expect(krb5_cc_store_cred(ctx, cacheHandle, &credentials) == 0)
        try value.withCString { value in
            var data = krb5_data(magic: 0, length: UInt32(strlen(value)), data: UnsafeMutablePointer(mutating: value))
            #expect(krb5_cc_set_config(ctx, cacheHandle, tgt, "pa_type", &data) == 0)
            let tickets = try TicketCache.read(context: ctx, cache: cacheHandle)
            #expect(tickets.count == 1)
            #expect(tickets.first?.method == expected)
            #expect(tickets.first?.principal == "user@EXAMPLE.INVALID")
            #expect(tickets.first?.starts == Date(timeIntervalSince1970: 1000))
            #expect(tickets.first?.expires == Date(timeIntervalSince1970: 2000))
            #expect(tickets.first?.renewable == true)
            #expect(tickets.first?.forwardable == true)
        }
    }
    // Heimdal kinit commonly has no pa_type entry. Replacement must clear the old method.
    #expect(krb5_cc_initialize(ctx, cacheHandle, client) == 0)
    #expect(krb5_cc_store_cred(ctx, cacheHandle, &credentials) == 0)
    #expect(try TicketCache.read(context: ctx, cache: cacheHandle).first?.method == .unknown)
    let selected = try #require(TicketCache.read(context: ctx, cache: cacheHandle).first)
    var service: krb5_principal?
    #expect(krb5_parse_name(ctx, "host/server@EXAMPLE.INVALID", &service) == 0)
    defer { krb5_free_principal(ctx, service) }
    credentials.server = service
    #expect(krb5_cc_store_cred(ctx, cacheHandle, &credentials) == 0)
    #expect(try TicketCache.read(context: ctx, cache: cacheHandle).count == 1)

    var unrelated: krb5_ccache?
    #expect(krb5_cc_new_unique(ctx, "MEMORY", nil, &unrelated) == 0)
    let other = try #require(unrelated)
    defer { krb5_cc_destroy(ctx, other) }
    #expect(krb5_cc_initialize(ctx, other, client) == 0)
    credentials.server = tgt
    credentials.ticket_flags = 0
    #expect(krb5_cc_store_cred(ctx, other, &credentials) == 0)
    let otherTicket = try #require(TicketCache.read(context: ctx, cache: other).first)
    #expect(!otherTicket.renewable && !otherTicket.forwardable)

    // A stale row must not destroy a cache whose TGT has been replaced.
    let stale = CachedTicket(cache: selected.cache, principal: selected.principal,
                             starts: selected.starts, expires: selected.expires.addingTimeInterval(-1),
                             method: selected.method)
    #expect(throws: CacheReadFailure.self) { try TicketCache.destroy(stale) }
    #expect(try TicketCache.read(context: ctx, cache: cacheHandle).first == selected)
    try TicketCache.destroy(selected)
    #expect(try TicketCache.read(context: ctx, cache: cacheHandle).isEmpty)
    #expect(try TicketCache.read(context: ctx, cache: other) == [otherTicket])
    // A missing cache must not stop the batch; duplicate rows must not destroy twice.
    #expect(TicketCache.destroyAll([selected, otherTicket, otherTicket]) == [selected.cache])
    #expect(try TicketCache.read(context: ctx, cache: other).isEmpty)
    #expect(TicketCache.destroyAll([]).isEmpty)
}

@Test func cacheActionsRequireExplicitSafeNames() {
    for name in ["", "API:", "MEMORY:", "FILE:/tmp/unrelated", "API:cache\0other"] {
        let ticket = CachedTicket(cache: name, principal: "user@EXAMPLE.INVALID",
                                  starts: .distantPast, expires: .distantFuture, method: .unknown)
        #expect(throws: CacheReadFailure.self) { try TicketCache.destroy(ticket) }
        #expect(throws: CacheReadFailure.self) { try TicketCache.verboseDetails(cache: name) }
    }
}
