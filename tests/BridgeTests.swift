import KerberosProbe
import Testing

@Test func swiftKerberosBridge() throws {
    #expect(try kerberosRuntimeName() == "MIT Kerberos")
}
