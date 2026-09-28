import BuildTestSupport
import KerberosProbe
import Testing

@Test func stockPKINITUsesBundledMIT() throws {
    let plugin = try artifact("KPASSKEY_KRB5").appendingPathComponent(
        "lib/krb5/plugins/preauth/pkinit.so"
    )
    try loadPKINIT(at: plugin.path)
}
