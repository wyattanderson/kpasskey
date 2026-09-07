import DependencyProbe
import KerberosProbe
import Testing

@Test func inMemoryProfile() throws {
  #expect(try configuredRealm() == "BUILD.INVALID")
}

@Test func bundledMITRuntime() throws {
  let path = try kerberosLibraryPath()
  #expect(path.contains("libkrb5.3.3.dylib"))
  #expect(!path.contains("/System/"))
}

@Test func fidoObjectLifetimes() throws {
  try allocateFIDOObjects()
}

@Test func cborEncoding() throws {
  #expect(try cborRoundTrip(42) == 42)
}

@Test func opensslDigest() throws {
  // Known SHA-256 of "probe", independent of the linked implementation.
  let expected: [UInt8] = [
    0xba, 0x9c, 0x73, 0x6f, 0x19, 0xe7, 0xf6, 0x0b,
    0x7f, 0x67, 0x64, 0xad, 0xb0, 0xb7, 0x90, 0x8c,
    0x0a, 0x2b, 0x39, 0x4e, 0x09, 0xb6, 0xc0, 0x98,
    0x63, 0x52, 0x8c, 0x7f, 0x2b, 0xc8, 0x60, 0x95,
  ]
  #expect(try sha256(Array("probe".utf8)) == expected)
}

@Test func zlibCompression() throws {
  let input = Array("probe".utf8)
  #expect(try zlibRoundTrip(input) == input)
}
