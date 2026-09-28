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
        0xBA, 0x9C, 0x73, 0x6F, 0x19, 0xE7, 0xF6, 0x0B,
        0x7F, 0x67, 0x64, 0xAD, 0xB0, 0xB7, 0x90, 0x8C,
        0x0A, 0x2B, 0x39, 0x4E, 0x09, 0xB6, 0xC0, 0x98,
        0x63, 0x52, 0x8C, 0x7F, 0x2B, 0xC8, 0x60, 0x95
    ]
    #expect(try sha256(Array("probe".utf8)) == expected)
}

@Test func zlibCompression() throws {
    let input = Array("probe".utf8)
    #expect(try zlibRoundTrip(input) == input)
}
