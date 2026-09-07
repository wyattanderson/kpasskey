import KerberosProbe

@main
struct BridgeMain {
  static func main() throws {
    try check(try kerberosRuntimeName() == "MIT Kerberos", "Unexpected runtime name")
  }
}
