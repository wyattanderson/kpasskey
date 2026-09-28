import CFIDO2
import CryptoKit
import Foundation

/// Application-owned plugin diagnostics, outside the POSIX errno range. MIT
/// preserves prep_questions errors but can wrap process errors in PREAUTH_FAILED.
/// Never attach challenge or credential contents.
public enum WireError: Int32, Error {
    case invalid = 100_001
    case framing, json, phase, state, rpInvalid, uvPolicy
    case credentials // Retired; preserves later raw values across plugin/app versions.
    case challengeHash
    case realmMismatch, configuration, armor, callbacks
}

public let passkeyQuestion = "org.kpasskey.assertion"
public let maximumWireSize = 65536
private let wirePrefix = Data("passkey ".utf8)

public struct Envelope<T: Codable & Sendable>: Codable, Sendable {
    public let phase: Int
    public let state: String
    public let data: T

    public init(phase: Int, state: String, data: T) {
        self.phase = phase
        self.state = state
        self.data = data
    }
}

public struct Challenge: Codable, Sendable {
    public let domain: String
    public let credentialIDList: [String]
    public let userVerification: Int
    public let cryptographicChallenge: String

    enum CodingKeys: String, CodingKey {
        case domain
        case credentialIDList = "credential_id_list"
        case userVerification = "user_verification"
        case cryptographicChallenge = "cryptographic_challenge"
    }

    public func validate() throws {
        // libfido2 receives a C string while verification hashes this Swift string.
        guard !domain.utf8.contains(0) else { throw WireError.rpInvalid }

        // Unknown wire values must not make required user verification optional.
        guard [0, 1].contains(userVerification) else { throw WireError.uvPolicy }

        // The protocol signs this value as a SHA-256 client-data hash.
        guard let hash = try? binary(cryptographicChallenge, maximum: 32), hash.count == 32
        else { throw WireError.challengeHash }
    }
}

public struct Assertion: Codable, Sendable {
    public let credentialID: String
    public let cryptographicChallenge: String
    public let authenticatorData: String
    public let assertionSignature: String
    public let userID: String?

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case cryptographicChallenge = "cryptographic_challenge"
        case authenticatorData = "authenticator_data"
        case assertionSignature = "assertion_signature"
        case userID = "user_id"
    }

    public init(credential: Data, challenge: String, authdata: Data, signature: Data, user: Data?) {
        credentialID = credential.base64EncodedString()
        cryptographicChallenge = challenge
        authenticatorData = authdata.base64EncodedString()
        assertionSignature = signature.base64EncodedString()

        // SSSD accepts an absent user handle; older consumers also accept an empty string.
        userID = user?.base64EncodedString()
    }

    public func validate(challenge: Challenge) throws {
        guard challenge.credentialIDList.contains(credentialID),
              cryptographicChallenge.utf8.elementsEqual(challenge.cryptographicChallenge.utf8)
        else { throw WireError.invalid }

        _ = try binary(credentialID, maximum: 1024)
        _ = try binary(assertionSignature, maximum: 2048)
        if let userID, !userID.isEmpty {
            _ = try binary(userID, maximum: 64)
        }
        let authdata = try binary(authenticatorData, maximum: 16384)

        var assertion = fido_assert_new()
        guard let handle = assertion else { throw WireError.invalid }
        defer { fido_assert_free(&assertion) }

        // libfido2 accepts a valid CBOR prefix, so also require it to consume every byte.
        guard fido_assert_set_count(handle, 1) == FIDO_OK,
              authdata.withUnsafeBytes({ fido_assert_set_authdata(handle, 0, $0.baseAddress, $0.count) }) == FIDO_OK,
              fido_assert_authdata_len(handle, 0) == authdata.count,
              let raw = fido_assert_authdata_raw_ptr(handle, 0), fido_assert_authdata_raw_len(handle, 0) >= 37,
              Data(bytes: raw, count: 32) == Data(SHA256.hash(data: Data(challenge.domain.utf8))),
              fido_assert_flags(handle, 0) & 1 != 0,
              challenge.userVerification == 0 || fido_assert_flags(handle, 0) & 4 != 0
        else { throw WireError.invalid }
    }
}

public func binary(_ text: String, maximum: Int) throws -> Data {
    guard !text.isEmpty, text.utf8.count <= ((maximum + 2) / 3) * 4,
          let bytes = Data(base64Encoded: text), !bytes.isEmpty, bytes.count <= maximum,
          bytes.base64EncodedString() == text
    else { throw WireError.invalid }

    return bytes
}

public func decodeWire<T>(_ bytes: Data, as _: T.Type, phase: Int) throws -> Envelope<T> {
    guard bytes.count <= maximumWireSize, bytes.starts(with: wirePrefix), bytes.last == 0,
          !bytes.dropLast().contains(0)
    else { throw WireError.framing }

    let envelope: Envelope<T>
    do {
        envelope = try JSONDecoder().decode(Envelope<T>.self,
                                            from: bytes.dropFirst(wirePrefix.count).dropLast())
    } catch { throw WireError.json }

    guard envelope.phase == phase else { throw WireError.phase }
    guard !envelope.state.isEmpty, envelope.state.utf8.count <= 4096,
          !envelope.state.utf8.contains(0)
    else { throw WireError.state }

    return envelope
}

public func encodeWire(_ envelope: Envelope<some Any>) throws -> Data {
    let bytes = try wirePrefix + (JSONEncoder().encode(envelope)) + Data([0])
    guard bytes.count <= maximumWireSize else { throw WireError.invalid }
    return bytes
}

/// MIT responder strings have no supplied length. Bound the scan before copying.
public func responderBytes(_ pointer: UnsafePointer<CChar>) throws -> Data {
    let count = strnlen(pointer, maximumWireSize)
    guard count < maximumWireSize else { throw WireError.invalid }
    return Data(bytes: pointer, count: count + 1)
}
