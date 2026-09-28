import CMITKerberos
import Darwin

public struct ProbeFailure: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ProbeFailure(message) }
}

public func kerberosRuntimeName() throws -> String {
    var profile: profile_t?
    try check(profile_init(nil, &profile) == 0, "profile_init failed")
    defer { profile_release(profile) }
    var context: krb5_context?
    try check(
        krb5_init_context_profile(profile, KRB5_INIT_CONTEXT_SECURE, &context) == 0,
        "krb5_init_context_profile failed"
    )
    defer { krb5_free_context(context) }
    return "MIT Kerberos"
}

public func configuredRealm() throws -> String {
    var profile: profile_t?
    try check(profile_init(nil, &profile) == 0, "profile_init failed")
    defer { profile_release(profile) }
    // C retains no relation pointers. Keep both strings alive for the call.
    let status = "libdefaults".withCString { section in
        "default_realm".withCString { key in
            var relation: [UnsafePointer<CChar>?] = [section, key, nil]
            return profile_add_relation(profile, &relation, "BUILD.INVALID")
        }
    }
    try check(status == 0, "profile_add_relation failed")
    var context: krb5_context?
    try check(
        krb5_init_context_profile(profile, KRB5_INIT_CONTEXT_SECURE, &context) == 0,
        "krb5_init_context_profile failed"
    )
    defer { krb5_free_context(context) }
    var realm: UnsafeMutablePointer<CChar>?
    try check(krb5_get_default_realm(context, &realm) == 0, "krb5_get_default_realm failed")
    guard let realm else { throw ProbeFailure("MIT returned a null realm") }
    defer { krb5_free_default_realm(context, realm) }
    return String(cString: realm)
}

/// dladdr/dlsym require a raw address; preserve the imported C calling convention.
private var contextFunctionAddress: UnsafeMutableRawPointer {
    let function: @convention(c) (UnsafeMutablePointer<krb5_context?>?) -> krb5_error_code =
        krb5_init_context
    return unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
}

public func kerberosLibraryPath() throws -> String {
    var origin = Dl_info()
    try check(dladdr(contextFunctionAddress, &origin) != 0, "dladdr failed for MIT context")
    guard let path = origin.dli_fname else { throw ProbeFailure("Missing MIT library origin") }
    return String(cString: path)
}

public func loadPKINIT(at path: String) throws {
    guard let plugin = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        throw ProbeFailure(dlerror().map { String(cString: $0) } ?? "dlopen failed")
    }
    do {
        try check(dlsym(plugin, "clpreauth_pkinit_initvt") != nil, "Missing client PKINIT entry point")
        try check(dlsym(plugin, "kdcpreauth_pkinit_initvt") != nil, "Missing KDC PKINIT entry point")
        try check(
            dlsym(plugin, "krb5_init_context") == contextFunctionAddress,
            "PKINIT uses a different MIT runtime"
        )
    } catch {
        dlclose(plugin)
        throw error
    }
    try check(dlclose(plugin) == 0, "dlclose failed")
}
