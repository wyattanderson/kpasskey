import CMITKerberos
import Foundation
import KPasskeyContract
import PasskeyWire

public struct KerberosFailure: Error, Sendable {
    public let status: Status
    public let code: Int32

    public init(_ status: Status, code: Int32 = 0) {
        self.status = status
        self.code = code
    }
}

func checked(_ code: Int32, _ status: Status = .configurationInvalid) throws {
    if code != 0 {
        throw KerberosFailure(status, code: code)
    }
}

/// Short lock only at the commit decision; never held across a library call.
public final class PublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committing = false
    private let deadline: ContinuousClock.Instant?

    public init(deadline: ContinuousClock.Instant? = nil) {
        self.deadline = deadline
    }

    @discardableResult public func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !committing else { return false }
        cancelled = true
        return true
    }

    public func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            throw KerberosFailure(.cancelled)
        }
        if let deadline, ContinuousClock.now >= deadline {
            throw KerberosFailure(.deadlineExceeded)
        }
    }

    public func beginPublication() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            throw KerberosFailure(.cancelled)
        }
        if let deadline, ContinuousClock.now >= deadline {
            throw KerberosFailure(.deadlineExceeded)
        }
        committing = true
    }
}

/// MIT owns lookup, copying and iteration. No file names or custom vtable are needed.
public func makeProfile(_ settings: Configuration, plugin: String? = nil,
                        armor: Bool = false, anchors: String? = nil) throws -> profile_t {
    guard settings.valid else { throw KerberosFailure(.configurationInvalid) }
    var profile: profile_t?
    try checked(Int32(profile_init(nil, &profile)))
    guard let profile else { throw KerberosFailure(.configurationInvalid) }
    do {
        func add(_ names: [String], _ value: String) throws {
            var strings: [UnsafeMutablePointer<CChar>] = []
            defer {
                for string in strings {
                    free(string)
                }
            }
            for name in names {
                guard let string = strdup(name) else { throw KerberosFailure(.configurationInvalid) }
                strings.append(string)
            }

            var pointers = strings.map { Optional(UnsafePointer($0)) } + [nil]
            try checked(Int32(profile_add_relation(profile, &pointers, value)))
        }
        let dns = settings.dnsDiscovery ? "true" : "false"
        for (key, value) in [
            "dns_lookup_kdc": settings.kdcs.isEmpty ? dns : "false",
            "dns_uri_lookup": settings.kdcs.isEmpty ? dns : "false",
            "dns_lookup_realm": dns, "rdns": "false", "dns_canonicalize_hostname": "false",
            "canonicalize": settings.canonicalize ? "true" : "false",
            "forwardable": settings.forwardable ? "true" : "false",
            "request_timeout": "\(settings.networkTimeoutSeconds)s",
            "udp_preference_limit": settings.transport == .tcpFirst ? "1" : "32700",
            "plugin_base_dir": "/nonexistent/kpasskey/plugins",
            "default_ccache_name": "MEMORY:KPasskey-unused", "allow_weak_crypto": "false"
        ] {
            try add(["libdefaults", key], value)
        }
        if !settings.effectiveRealm.isEmpty {
            try add(["libdefaults", "default_realm"], settings.effectiveRealm)
        }
        for kdc in settings.kdcs {
            try add(["realms", settings.effectiveRealm, "kdc"], kdc.address)
        }
        if settings.mode == .passkey {
            guard let plugin else { throw KerberosFailure(.configurationInvalid) }
            let module = armor ? "pkinit" : "kpasskey"
            try add(["plugins", "clpreauth", "module"], module + ":" + plugin)
            try add(["plugins", "clpreauth", "enable_only"], module)
            try add(["kpasskey", "realm"], settings.effectiveRealm)
            if armor {
                guard let anchors else { throw KerberosFailure(.configurationInvalid) }
                try add(["realms", settings.effectiveRealm, "pkinit_anchors"], "FILE:" + anchors)
                try add(["realms", settings.effectiveRealm, "pkinit_eku_checking"], "kpKDC")
            }
        } else {
            try add(["plugins", "clpreauth", "enable_only"], "encrypted_timestamp")
        }
        // No heuristic uppercase-domain fallback: realm discovery must come from DNS or the snapshot.
        for module in ["profile", "dns"] {
            try add(["plugins", "hostrealm", "enable_only"], module)
        }
        return profile
    } catch {
        profile_abandon(profile)
        throw error
    }
}

public func makeContext(_ settings: Configuration, plugin: String? = nil,
                        armor: Bool = false, anchors: String? = nil) throws -> krb5_context {
    let profile = try makeProfile(settings, plugin: plugin, armor: armor, anchors: anchors)
    defer { profile_abandon(profile) }
    var context: krb5_context?
    try checked(krb5_init_context_profile(profile, KRB5_INIT_CONTEXT_SECURE, &context))
    guard let context else { throw KerberosFailure(.configurationInvalid) }
    do {
        try checked(krb5_cc_set_default_name(context, "MEMORY:" + UUID().uuidString))
        return context
    } catch {
        krb5_free_context(context)
        throw error
    }
}

public func resolvePrincipal(_ settings: Configuration, context: krb5_context) throws -> krb5_principal {
    if settings.effectiveRealm.isEmpty, !settings.discoveryDomain.isEmpty {
        var realms: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var domain = Array(settings.discoveryDomain.utf8CString)
        try domain.withUnsafeMutableBufferPointer { buffer in
            var data = krb5_data(magic: 0, length: UInt32(buffer.count - 1), data: buffer.baseAddress)
            try checked(krb5_get_fallback_host_realm(context, &data, &realms))
        }
        defer { krb5_free_host_realm(context, realms) }
        guard let realm = realms?.pointee, realm.pointee != 0 else {
            throw KerberosFailure(.configurationInvalid)
        }
        try checked(krb5_set_default_realm(context, realm))
    }
    var principal: krb5_principal?
    try checked(krb5_parse_name(context, settings.principal, &principal))
    guard let principal else { throw KerberosFailure(.configurationInvalid) }
    return principal
}

public func credentialOptions(_ settings: Configuration, context: krb5_context)
    throws -> UnsafeMutablePointer<krb5_get_init_creds_opt> {
    var options: UnsafeMutablePointer<krb5_get_init_creds_opt>?
    try checked(krb5_get_init_creds_opt_alloc(context, &options))
    guard let options else { throw KerberosFailure(.configurationInvalid) }
    krb5_get_init_creds_opt_set_forwardable(options, settings.forwardable ? 1 : 0)
    krb5_get_init_creds_opt_set_proxiable(options, 0)
    krb5_get_init_creds_opt_set_canonicalize(options, settings.canonicalize ? 1 : 0)
    krb5_get_init_creds_opt_set_tkt_life(options, Int32(settings.lifetimeSeconds))
    krb5_get_init_creds_opt_set_renew_life(options, Int32(settings.renewableLifetimeSeconds))
    krb5_get_init_creds_opt_set_change_password_prompt(options, 0)
    return options
}

public func authenticationStatus(_ code: Int32) -> Status {
    if WireError(rawValue: code) != nil {
        return .passkeyInvalid
    }
    switch code {
    case Int32(KRB5KDC_ERR_PREAUTH_FAILED), Int32(KRB5KRB_AP_ERR_BAD_INTEGRITY),
         Int32(KRB5KDC_ERR_C_PRINCIPAL_UNKNOWN), Int32(KRB5KDC_ERR_CLIENT_REVOKED),
         Int32(KRB5KDC_ERR_KEY_EXP): return .credentialsRejected
    case Int32(KRB5_KDC_UNREACH), Int32(KRB5_REALM_CANT_RESOLVE): return .kdcUnavailable
    case Int32(KRB5_REALM_UNKNOWN), Int32(KRB5_CONFIG_NODEFREALM): return .configurationInvalid
    case Int32(KRB5_LIBOS_CANTREADPWD): return .unexpectedPrompt
    default: return .authenticationFailed
    }
}

/// Synchronous and confined to an operation thread. All native handles stay on that thread.
public func acquirePassword(_ settings: Configuration, password: Data, gate: PublicationGate)
    throws -> TicketMetadata {
    guard settings.valid, settings.mode == .password,
          !password.isEmpty, password.count <= 4096, !password.contains(0)
    else {
        throw KerberosFailure(.configurationInvalid)
    }
    try gate.check()
    let context = try makeContext(settings)
    defer { krb5_free_context(context) }
    let principal = try resolvePrincipal(settings, context: context)
    defer { krb5_free_principal(context, principal) }
    let options = try credentialOptions(settings, context: context)
    defer { krb5_get_init_creds_opt_free(context, options) }
    var staging: krb5_ccache?
    try checked(krb5_cc_new_unique(context, "MEMORY", nil, &staging))
    guard let staging else { throw KerberosFailure(.configurationInvalid) }
    defer { krb5_cc_destroy(context, staging) }
    try checked(krb5_get_init_creds_opt_set_out_ccache(context, options, staging))

    var credentials = krb5_creds()
    defer { krb5_free_cred_contents(context, &credentials) }
    var bytes = Array(password) + [0]
    defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    try gate.check()
    let code = bytes.withUnsafeMutableBytes { buffer -> Int32 in
        guard let baseAddress = buffer.baseAddress else { return Int32(KRB5_LIBOS_CANTREADPWD) }
        return krb5_get_init_creds_password(context, &credentials, principal,
                                            baseAddress.assumingMemoryBound(to: CChar.self),
                                            { _, _, _, _, _, _ in Int32(KRB5_LIBOS_CANTREADPWD) }, nil, 0, nil, options)
    }
    try gate.check()
    try checked(code, authenticationStatus(code))
    return try publish(context: context, staging: staging, credentials: &credentials,
                       makeDefault: settings.makeDefault, gate: gate)
}

/// Commit creates a fresh API cache. Rollback destroys only that newly owned cache.
public func publish(context: krb5_context, staging: krb5_ccache,
                    credentials: inout krb5_creds, makeDefault: Bool, gate: PublicationGate,
                    mode: String = "password",
                    createCache: (krb5_context, UnsafeMutablePointer<krb5_ccache?>) -> Int32 = {
                        krb5_cc_new_unique($0, "API", nil, $1)
                    })
    throws -> TicketMetadata {
    guard let client = credentials.client else { throw KerberosFailure(.publicationFailed) }
    var name: UnsafeMutablePointer<CChar>?
    try checked(krb5_unparse_name(context, client, &name), .publicationFailed)
    guard let name else { throw KerberosFailure(.publicationFailed) }
    defer { krb5_free_unparsed_name(context, name) }
    let principal = String(cString: name)
    let realmData = client.pointee.realm
    // Keep native principal metadata conversion total for display and reporting.
    // swiftlint:disable:next optional_data_string_conversion
    let realm = String(decoding: UnsafeRawBufferPointer(start: realmData.data,
                                                        count: Int(realmData.length)), as: UTF8.self)

    // Validate metadata before any shared-cache side effect.
    let metadata = TicketMetadata(principal: principal, realm: realm, cache: "API:pending",
                                  expires: Int(credentials.times.endtime),
                                  renewUntil: Int(credentials.times.renew_till),
                                  forwardable: credentials.ticket_flags & TKT_FLG_FORWARDABLE != 0, mode: mode)
    guard metadata.valid else { throw KerberosFailure(.publicationFailed) }
    try gate.beginPublication()
    var destination: krb5_ccache?
    try checked(createCache(context, &destination), .publicationFailed)
    guard let destination else { throw KerberosFailure(.publicationFailed) }
    var committed = false
    defer {
        if committed {
            krb5_cc_close(context, destination)
        } else {
            krb5_cc_destroy(context, destination)
        }
    }
    try checked(krb5_cc_initialize(context, destination, client), .publicationFailed)
    try checked(krb5_cc_copy_creds(context, staging, destination), .publicationFailed)
    var cacheName: UnsafeMutablePointer<CChar>?
    try checked(krb5_cc_get_full_name(context, destination, &cacheName), .publicationFailed)
    guard let cacheName else { throw KerberosFailure(.publicationFailed) }
    defer { krb5_free_string(context, cacheName) }
    let result = TicketMetadata(principal: principal, realm: realm, cache: String(cString: cacheName),
                                expires: metadata.expires, renewUntil: metadata.renewUntil,
                                forwardable: metadata.forwardable, mode: mode)
    guard result.valid else { throw KerberosFailure(.publicationFailed) }
    if makeDefault {
        try checked(krb5_cc_switch(context, destination), .publicationFailed)
    }
    committed = true
    return result
}
