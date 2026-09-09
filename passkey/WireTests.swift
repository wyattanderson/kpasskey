import CFIDO2
import CryptoKit
import Foundation
import PasskeyWire
import Testing

// Synthetic inputs written independently of the production encoder.
let hashText = Data(repeating: 0x5a, count: 32).base64EncodedString()
func challengeFixture(_ changes: [String: Any] = [:], phase: Any = 1) throws -> Data {
  var payload: [String: Any] = ["domain": "example.org", "credential_id_list": ["AQID"],
    "user_verification": 1, "cryptographic_challenge": hashText]
  payload.merge(changes) { _, new in new }
  return Data("passkey ".utf8) + (try JSONSerialization.data(withJSONObject:
    ["phase": phase, "state": "opaque-state-é", "data": payload])) + Data([0])
}
func fixtureAssertion(uv: Bool = true, raw: Bool = false) -> Assertion {
  let body = Data(SHA256.hash(data: Data("example.org".utf8))) + Data([uv ? 5 : 1, 0, 0, 0, 1])
  return Assertion(credential: Data([1, 2, 3]), challenge: hashText,
    authdata: (raw ? Data() : Data([0x58, 0x25])) + body,
    signature: Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]), user: nil)
}

@Test func serverReplyOracle() throws {
  let input = try decodeWire(challengeFixture(), as: Challenge.self, phase: 1)
  try input.data.validate(rp: "example.org")
  let assertion = fixtureAssertion()
  try assertion.validate(challenge: input.data)
  let bytes = try encodeWire(Envelope(phase: 2, state: input.state, data: assertion))
  // Independent Foundation object decoder implements the KDC cookie predicates;
  // it never calls the production decoder or uses a production reply round trip.
  #expect(bytes.prefix(8) == Data("passkey ".utf8)); #expect(bytes.last == 0)
  let object = try #require(JSONSerialization.jsonObject(with: bytes.dropFirst(8).dropLast()) as? [String: Any])
  #expect(object["phase"] as? Int == 2)
  #expect((object["state"] as? String)?.utf8.elementsEqual("opaque-state-é".utf8) == true)
  let data = try #require(object["data"] as? [String: String])
  #expect(data["cryptographic_challenge"] == hashText)
  #expect(data["credential_id"] == "AQID")
  #expect(data["user_id"] == nil)
  let authText = try #require(data["authenticator_data"])
  let auth = try #require(Data(base64Encoded: authText))
  // The server's prepare_assert() calls this actual upstream decoder, not the raw setter.
  var native = fido_assert_new()
  defer { fido_assert_free(&native) }
  #expect(fido_assert_set_count(native, 1) == FIDO_OK)
  #expect(auth.withUnsafeBytes { fido_assert_set_authdata(native, 0, $0.baseAddress, $0.count) } == FIDO_OK)
  #expect(fido_assert_authdata_raw_len(native, 0) == 37)
  #expect(fido_assert_flags(native, 0) == 5)
  // Independently sign synthetic authenticator data, then use the server's
  // libfido2 verification path (including DER ECDSA and CBOR decoding).
  let key = P256.Signing.PrivateKey()
  let signed = Data(auth.dropFirst(2)) + Data(repeating: 0x5a, count: 32)
  let signature = try key.signature(for: signed).derRepresentation
  var publicKey = es256_pk_new()
  defer { es256_pk_free(&publicKey) }
  #expect(key.publicKey.rawRepresentation.withUnsafeBytes {
    es256_pk_from_ptr(publicKey, $0.baseAddress, $0.count)
  } == FIDO_OK)
  #expect(fido_assert_set_rp(native, "example.org") == FIDO_OK)
  #expect(Data(repeating: 0x5a, count: 32).withUnsafeBytes {
    fido_assert_set_clientdata_hash(native, $0.baseAddress, $0.count)
  } == FIDO_OK)
  #expect(fido_assert_set_up(native, FIDO_OPT_TRUE) == FIDO_OK)
  #expect(fido_assert_set_uv(native, FIDO_OPT_TRUE) == FIDO_OK)
  #expect(signature.withUnsafeBytes { fido_assert_set_sig(native, 0, $0.baseAddress, $0.count) } == FIDO_OK)
  #expect(fido_assert_verify(native, 0, COSE_ES256, publicKey.map { UnsafeRawPointer($0) }) == FIDO_OK)
  #expect(fido_assert_set_rp(native, "other.example.org") == FIDO_OK)
  #expect(fido_assert_verify(native, 0, COSE_ES256, publicKey.map { UnsafeRawPointer($0) }) != FIDO_OK)
}

@Test func rejectMalformedChallengesAndFraming() throws {
  let good = try challengeFixture()
  for bad in [Data(), good.dropLast(), good + Data([0]), Data(good.dropFirst()),
              good + Data(repeating: 0x20, count: maximumWireSize),
              try challengeFixture(phase: 0), try challengeFixture(phase: 2),
              try challengeFixture(phase: true), Data("passkey {\"phase\":1}\0".utf8)] {
    #expect(throws: (any Error).self) { try decodeWire(Data(bad), as: Challenge.self, phase: 1) }
  }
  for changes: [String: Any] in [
    ["domain": "example.org.evil"], ["domain": "EXAMPLE.ORG"],
    ["credential_id_list": []], ["credential_id_list": ["AQID", "AQID"]],
    ["credential_id_list": Array(repeating: "AQID", count: 65)],
    ["credential_id_list": ["AQ-D"]], ["credential_id_list": ["AR=="]],
    ["user_verification": 2], ["user_verification": -1], ["user_verification": true],
    ["cryptographic_challenge": "AA=="], ["cryptographic_challenge": hashText + "\n"],
  ] {
    #expect(throws: (any Error).self) {
      let decoded = try decodeWire(challengeFixture(changes), as: Challenge.self, phase: 1)
      try decoded.data.validate(rp: "example.org")
    }
  }
}

@Test func rejectRawMalformedAndUnverifiedAuthdata() throws {
  let challenge = try decodeWire(challengeFixture(), as: Challenge.self, phase: 1).data
  for assertion in [fixtureAssertion(uv: false), fixtureAssertion(raw: true),
    Assertion(credential: Data([1, 2, 3]), challenge: hashText, authdata: Data([0x58, 0xff]),
              signature: Data([1]), user: nil),
    Assertion(credential: Data([4]), challenge: hashText, authdata: Data([0]), signature: Data([1]), user: nil)] {
    #expect(throws: (any Error).self) { try assertion.validate(challenge: challenge) }
  }
  let valid = fixtureAssertion()
  let auth = try binary(valid.authenticator_data, maximum: 16_384)
  for bytes in [auth + Data([0]), Data(auth.dropLast()), Data([0xbf, 0xff]), Data([0x5f, 0xff])] {
    let invalid = Assertion(credential: Data([1, 2, 3]), challenge: hashText,
                            authdata: bytes, signature: Data([1]), user: nil)
    #expect(throws: (any Error).self) { try invalid.validate(challenge: challenge) }
  }
  let optionalUV = try decodeWire(challengeFixture(["user_verification": 0]), as: Challenge.self, phase: 1).data
  try fixtureAssertion(uv: false).validate(challenge: optionalUV)
}
