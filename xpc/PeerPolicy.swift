import Foundation
import Security

public enum PeerPolicyError: Error { case invalidCode, missingTeam, invalidIdentity }

public enum PeerPolicy {
  /// XPC evaluates this requirement against the actual peer, on every message.
  public static func requirement(peer: URL, identifier: String) throws -> String {
    guard [hostIdentifier, applicationIdentifier, workerIdentifier, applicationWorkerIdentifier].contains(identifier) else {
      throw PeerPolicyError.invalidIdentity
    }
    var ownCode: SecCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else {
      throw PeerPolicyError.invalidCode
    }
    var ownStaticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode
    else {
      throw PeerPolicyError.invalidCode
    }
    var ownInfo: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
        &ownInfo) == errSecSuccess,
      let info = ownInfo as? [String: Any]
    else { throw PeerPolicyError.invalidCode }
    if let team = info[kSecCodeInfoTeamIdentifier as String] as? String {
      return try releaseRequirement(team: team, identifier: identifier)
    }
    #if DEVELOPMENT_PEERS
      var code: SecStaticCode?
      guard SecStaticCodeCreateWithPath(peer as CFURL, [], &code) == errSecSuccess,
        let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
      else { throw PeerPolicyError.invalidCode }
      var signingInfo: CFDictionary?
      guard
        SecCodeCopySigningInformation(
          code, SecCSFlags(rawValue: kSecCSSigningInformation),
          &signingInfo) == errSecSuccess,
        let signing = signingInfo as? [String: Any],
        signing[kSecCodeInfoIdentifier as String] as? String == identifier,
        let hash = signing[kSecCodeInfoUnique as String] as? Data
      else { throw PeerPolicyError.invalidIdentity }
      return
        "identifier \"\(identifier)\" and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    #else
      throw PeerPolicyError.missingTeam
    #endif
  }

  public static func releaseRequirement(team: String, identifier: String) throws -> String {
    guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
      [hostIdentifier, applicationIdentifier, workerIdentifier, applicationWorkerIdentifier].contains(identifier)
    else { throw PeerPolicyError.invalidIdentity }
    return
      "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
  }
}
