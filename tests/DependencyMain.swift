import DependencyProbe
import KerberosProbe

@main
struct DependencyMain {
  static func main() throws {
    try check(CommandLine.arguments.count <= 2, "Usage: dependency_app [pkinit-path]")
    try verifyDependencies()
    if CommandLine.arguments.count == 2 {
      try loadPKINIT(at: CommandLine.arguments[1])
    }
    print("MIT profile/context, FIDO objects, CBOR, OpenSSL, zlib and requested PKINIT load: OK")
  }
}
