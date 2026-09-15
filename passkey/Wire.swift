import CFIDO2
import CCBOR
import CryptoKit
import Foundation

// Application-owned plugin diagnostics, outside the POSIX errno range. MIT
// preserves prep_questions errors but can wrap process errors in PREAUTH_FAILED.
// Never attach challenge or credential contents.
public enum WireError: Int32, Error {
  case invalid = 100_001
  case framing, json, phase, state, rpInvalid, uvPolicy, credentials, challengeHash
  case realmMismatch, configuration, armor, callbacks
}
public let passkeyQuestion = "org.kpasskey.assertion"
public let maximumWireSize = 65_536

public struct Envelope<T: Codable & Sendable>: Codable, Sendable {
  public let phase: Int
  public let state: String
  public let data: T
  public init(phase: Int, state: String, data: T) {
    self.phase = phase; self.state = state; self.data = data
  }
}

public struct Challenge: Codable, Sendable {
  public let domain: String
  public let credential_id_list: [String]
  public let user_verification: Int
  public let cryptographic_challenge: String

  public func validate() throws {
    // libfido2 receives a C string but assertion verification hashes this Swift string; reject truncation.
    guard !domain.utf8.contains(0) else { throw WireError.rpInvalid }
    // We map this wire policy to CTAP's required/omitted UV option; unknown values must not downgrade UV.
    guard [0, 1].contains(user_verification) else { throw WireError.uvPolicy }
    // This protocol signs a SHA-256 client-data hash, so a different length cannot produce a valid assertion.
    do {
      guard try binary(cryptographic_challenge, maximum: 32).count == 32 else { throw WireError.invalid }
    } catch { throw WireError.challengeHash }
  }
}

public struct Assertion: Codable, Sendable {
  public let credential_id: String
  public let cryptographic_challenge: String
  public let authenticator_data: String
  public let assertion_signature: String
  public let user_id: String?

  public init(credential: Data, challenge: String, authdata: Data, signature: Data, user: Data?) {
    credential_id = credential.base64EncodedString()
    cryptographic_challenge = challenge
    authenticator_data = authdata.base64EncodedString()
    assertion_signature = signature.base64EncodedString()
    // SSSD accepts an absent user handle; older consumers also accept an empty string.
    user_id = user?.base64EncodedString()
  }

  public func validate(challenge: Challenge) throws {
    guard challenge.credential_id_list.contains(credential_id),
      cryptographic_challenge.utf8.elementsEqual(challenge.cryptographic_challenge.utf8)
    else { throw WireError.invalid }
    _ = try binary(credential_id, maximum: 1024)
    _ = try binary(assertion_signature, maximum: 2048)
    if let user_id, !user_id.isEmpty { _ = try binary(user_id, maximum: 64) }
    let authdata = try binary(authenticator_data, maximum: 16_384)
    var loaded = cbor_load_result()
    var item = authdata.withUnsafeBytes {
      cbor_load($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count, &loaded)
    }
    defer { if item != nil { cbor_decref(&item) } }
    guard let parsed = item, loaded.read == authdata.count,
      cbor_isa_bytestring(parsed), cbor_bytestring_is_definite(parsed) else { throw WireError.invalid }
    var assertion = fido_assert_new()
    guard let handle = assertion else { throw WireError.invalid }
    defer { fido_assert_free(&assertion) }
    guard fido_assert_set_count(handle, 1) == FIDO_OK,
      authdata.withUnsafeBytes({ fido_assert_set_authdata(handle, 0, $0.baseAddress, $0.count) }) == FIDO_OK,
      let raw = fido_assert_authdata_raw_ptr(handle, 0), fido_assert_authdata_raw_len(handle, 0) >= 37,
      Data(bytes: raw, count: 32) == Data(SHA256.hash(data: Data(challenge.domain.utf8))),
      fido_assert_flags(handle, 0) & 1 != 0,
      challenge.user_verification == 0 || fido_assert_flags(handle, 0) & 4 != 0
    else { throw WireError.invalid }
  }
}

public func binary(_ text: String, maximum: Int) throws -> Data {
  guard !text.isEmpty, text.utf8.count <= ((maximum + 2) / 3) * 4,
    let bytes = Data(base64Encoded: text), !bytes.isEmpty, bytes.count <= maximum,
    bytes.base64EncodedString() == text else { throw WireError.invalid }
  return bytes
}

public func decodeWire<T>(_ bytes: Data, as: T.Type, phase: Int) throws -> Envelope<T> {
  guard bytes.count <= maximumWireSize, bytes.starts(with: Data("passkey ".utf8)),
    bytes.last == 0, !bytes.dropLast().contains(0) else { throw WireError.framing }
  let envelope: Envelope<T>
  do { envelope = try JSONDecoder().decode(Envelope<T>.self, from: bytes.dropFirst(8).dropLast()) }
  catch { throw WireError.json }
  guard envelope.phase == phase else { throw WireError.phase }
  guard !envelope.state.isEmpty, envelope.state.utf8.count <= 4096,
    !envelope.state.utf8.contains(0) else { throw WireError.state }
  return envelope
}

public func encodeWire<T>(_ envelope: Envelope<T>) throws -> Data {
  let bytes = Data("passkey ".utf8) + (try JSONEncoder().encode(envelope)) + Data([0])
  guard bytes.count <= maximumWireSize else { throw WireError.invalid }
  return bytes
}

/// MIT responder strings have no supplied length. Bound the scan before copying.
public func responderBytes(_ pointer: UnsafePointer<CChar>) throws -> Data {
  let count = strnlen(pointer, maximumWireSize)
  guard count < maximumWireSize else { throw WireError.invalid }
  return Data(bytes: pointer, count: count + 1)
}
