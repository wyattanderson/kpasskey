import KerberosProbe

@main
struct BridgeMain {
    static func main() throws {
        try check(kerberosRuntimeName() == "MIT Kerberos", "Unexpected runtime name")
    }
}
