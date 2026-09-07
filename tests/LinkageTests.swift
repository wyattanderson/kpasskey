import BuildTestSupport
import Foundation
import Testing

@Test func nativeArtifactsHaveExpectedLinkage() throws {
  let krb = try artifact("KPASSKEY_KRB5")
  let crypto = try artifact("KPASSKEY_OPENSSL")
  let plugin = krb.appendingPathComponent("lib/krb5/plugins/preauth/pkinit.so")
  let libraries = try dylibs(in: krb) + dylibs(in: crypto)
  let bundledNames = Set(libraries.map(\.lastPathComponent))
  for file in libraries + [plugin] {
    for dependency in try dependencies(of: file) {
      if dependency.hasPrefix("@rpath/") {
        #expect(
          bundledNames.contains(String(dependency.dropFirst(7))),
          "\(file.path): missing \(dependency)")
      } else {
        #expect(
          dependency.hasPrefix("/System/Library/Frameworks/") || dependency.hasPrefix("/usr/lib/"),
          "\(file.path): non-relocatable dependency \(dependency)")
      }
    }
    for rpath in try rpaths(of: file) {
      #expect(!rpath.hasPrefix("/"), "\(file.path): absolute rpath \(rpath)")
      #expect(
        !["homebrew", "usr/local", "execroot"].contains(where: rpath.contains),
        "\(file.path): host rpath \(rpath)")
    }
    try run("/usr/bin/codesign", ["--verify", file.path])
  }

  let executables = try [artifact("KPASSKEY_BRIDGE_APP"), artifact("KPASSKEY_DEPENDENCY_APP")]
  let testExecutables = try [
    artifact("KPASSKEY_BRIDGE_TEST"), artifact("KPASSKEY_DEPENDENCY_TEST"),
  ]
  let archives = try [
    "third_party/libfido2/lib/libfido2.a",
    "third_party/libcbor/lib/libcbor.a",
    "third_party/zlib/lib/libz.a",
  ].map { try runfile($0) }
  let architecture = try environment("KPASSKEY_ARCH")
  let minimumOS = try environment("KPASSKEY_MINIMUM_OS")
  for file in libraries + [plugin] + archives + executables + testExecutables {
    let actualArchitecture = try run("/usr/bin/lipo", ["-archs", file.path]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    #expect(actualArchitecture == architecture, "\(file.path)")
    let versions = try minimumOSVersions(of: file)
    #expect(!versions.isEmpty, "Missing minimum OS: \(file.path)")
    #expect(versions.allSatisfy { $0 == minimumOS }, "\(file.path): \(versions)")
  }
  for file in executables {
    try run("/usr/bin/codesign", ["--verify", file.path])
    let linkedLibraries = try dependencies(of: file)
    #expect(
      !linkedLibraries.contains {
        $0.contains("Testing.framework") || $0.contains("XCTest.framework")
      })
  }
  let mit = krb.appendingPathComponent("lib/libkrb5.3.3.dylib")
  let symbols = try run("/usr/bin/nm", ["-u", mit.path])
  #expect(symbols.split(separator: "\n").contains("_cc_initialize"))
  #expect(try run("/usr/bin/strings", [mit.path]).contains("com.apple.GSSCred"))
  #expect(try dependencies(of: mit).contains { $0.contains("/Kerberos.framework/") })
  #expect(try run("/usr/bin/nm", ["-gU", plugin.path]).contains(" _clpreauth_pkinit_initvt"))
}
