import CCBOR
import CFIDO2
import COpenSSL
import CZlib
import KerberosProbe

public func allocateFIDOObjects() throws {
    fido_init(0)
    var assertion = fido_assert_new()
    defer { fido_assert_free(&assertion) }
    var device = fido_dev_new()
    defer { fido_dev_free(&device) }
    try check(assertion != nil && device != nil, "FIDO object allocation failed")
}

public func cborRoundTrip(_ value: UInt8) throws -> UInt8 {
    var item = cbor_build_uint8(value)
    guard item != nil else { throw ProbeFailure("CBOR allocation failed") }
    defer { cbor_decref(&item) }
    return cbor_get_uint8(item)
}

public func sha256(_ input: [UInt8]) throws -> [UInt8] {
    // The synthesized numeric macro is not importable; the full version string
    // checks the same header/runtime agreement without duplicating its encoding.
    try check(
        String(cString: OpenSSL_version(OPENSSL_FULL_VERSION_STRING)) == OPENSSL_FULL_VERSION_STR,
        "OpenSSL header/runtime mismatch"
    )
    var digest = [UInt8](repeating: 0, count: Int(EVP_MAX_MD_SIZE))
    var length: UInt32 = 0
    let status = input.withUnsafeBytes { bytes in
        EVP_Digest(bytes.baseAddress, bytes.count, &digest, &length, EVP_sha256(), nil)
    }
    try check(status == 1, "EVP_Digest failed")
    return Array(digest.prefix(Int(length)))
}

public func zlibRoundTrip(_ input: [UInt8]) throws -> [UInt8] {
    try check(String(cString: zlibVersion()) == ZLIB_VERSION, "zlib header/runtime mismatch")
    var compressedLength = compressBound(uLong(input.count))
    var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
    let compression = input.withUnsafeBufferPointer { bytes in
        compress(&compressed, &compressedLength, bytes.baseAddress, uLong(bytes.count))
    }
    try check(compression == Z_OK, "compress failed")
    var restoredLength = uLongf(input.count)
    var restored = [UInt8](repeating: 0, count: input.count)
    try check(
        uncompress(&restored, &restoredLength, compressed, compressedLength) == Z_OK,
        "uncompress failed"
    )
    return Array(restored.prefix(Int(restoredLength)))
}

public func verifyDependencies() throws {
    try check(configuredRealm() == "BUILD.INVALID", "Unexpected configured realm")
    let path = try kerberosLibraryPath()
    try check(
        path.contains("libkrb5.3.3.dylib") && !path.contains("/System/"),
        "Unexpected MIT origin: \(path)"
    )
    try allocateFIDOObjects()
    try check(cborRoundTrip(42) == 42, "CBOR round trip failed")
    let input = Array("probe".utf8)
    try check(sha256(input).count == 32, "Wrong SHA-256 digest size")
    try check(zlibRoundTrip(input) == input, "zlib round trip failed")
}
