import Foundation
import Security

public struct Configuration: Codable, Sendable {
    public enum Transport: String, Codable, Sendable { case tcpFirst, udpFirst }
    public enum Mode: String, Codable, Sendable { case password, passkey }
    public var schema = 1
    public var principal: String
    public var realm = ""
    public var discoveryDomain = ""
    public var dnsDiscovery = true
    public var kdcs: [KDCEndpoint] = []
    public var transport: Transport = .tcpFirst
    public var canonicalize = false
    public var forwardable = true
    public var lifetimeSeconds = 36000
    public var renewableLifetimeSeconds = 604_800
    public var makeDefault = true
    public var timeoutMilliseconds = 30000
    public var networkTimeoutSeconds = 5
    public var mode: Mode = .password
    /// DER certificate supplied as plist Data, never an arbitrary worker-side file path.
    public var pkinitCA = Data()

    public init(principal: String) {
        self.principal = principal
    }

    /// A partial settings plist overlays typed defaults; unknown keys (including secrets) fail closed.
    public static func load(_ data: Data) throws -> Configuration {
        guard data.count <= 8192,
              var values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var defaults = try PropertyListSerialization.propertyList(
                  from: PropertyListEncoder().encode(Configuration(principal: "")), format: nil
              ) as? [String: Any],
              values.keys.allSatisfy({ $0 == "rpID" || defaults.keys.contains($0) })
        else { throw CocoaError(.coderInvalidValue) }
        // Migrate old settings without retaining an override for the KDC's RP ID.
        values.removeValue(forKey: "rpID")
        defaults.merge(values) { _, saved in saved }
        let effective = try PropertyListSerialization.data(fromPropertyList: defaults, format: .binary, options: 0)
        let settings = try PropertyListDecoder().decode(Configuration.self, from: effective)
        guard settings.valid, settings.mode != .passkey || settings.validPKINITCA
        else { throw CocoaError(.coderInvalidValue) }
        return settings
    }

    public var valid: Bool {
        schema == 1 && Self.text(principal) && !principal.isEmpty
            && !principal.contains("\\") && !principal.contains("/")
            && principal.split(separator: "@", omittingEmptySubsequences: false).count <= 2
            && !principal.hasPrefix("@") && !principal.hasSuffix("@")
            && Self.text(realm) && !realm.contains("@") && !realm.contains("/")
            && (discoveryDomain.isEmpty || KDCEndpoint.validHost(discoveryDomain))
            && kdcs.count <= 8 && kdcs.allSatisfy(\.valid)
            && (kdcs.isEmpty ? dnsDiscovery : !effectiveRealm.isEmpty)
            && (realm.isEmpty || !principal.contains("@") || principal.hasSuffix("@" + realm))
            && (300 ... 604_800).contains(lifetimeSeconds)
            && (0 ... 2_592_000).contains(renewableLifetimeSeconds)
            && (200 ... 30000).contains(timeoutMilliseconds)
            && (1 ... 30).contains(networkTimeoutSeconds)
            && (mode == .password
                ? pkinitCA.isEmpty
                : !effectiveRealm.isEmpty && !canonicalize && (1 ... 4096).contains(pkinitCA.count))
    }

    public var effectiveRealm: String {
        principal.contains("@")
            ? String(principal.split(separator: "@", omittingEmptySubsequences: false).last ?? "") : realm
    }

    /// Local realm binding for the selected trust anchor; PKINIT still verifies the KDC's SAN and EKU.
    public var validPKINITCA: Bool {
        guard !effectiveRealm.isEmpty, (1 ... 4096).contains(pkinitCA.count),
              let certificate = SecCertificateCreateWithData(nil, pkinitCA as CFData),
              let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil)
              as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let attributes = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return false }
        let organizations = attributes.filter {
            $0[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationName as String
        }
        guard organizations.count == 1,
              let organization = organizations[0][kSecPropertyKeyValue as String] as? String
        else { return false }
        return organization.utf8.elementsEqual(effectiveRealm.utf8)
    }

    static func text(_ value: String) -> Bool {
        value.utf8.count <= 256
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct KDCEndpoint: Codable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 88) {
        self.host = host
        self.port = port
    }

    public var valid: Bool {
        Self.validHost(host) && (1 ... 65535).contains(port)
    }

    public var address: String {
        "\(host):\(port)"
    }

    /// DNS names and IPv4 literals. IPv6 endpoints can be added with bracket validation.
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253
            && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.utf8.allSatisfy { (48 ... 57).contains($0) || (65 ... 90).contains($0)
                        || (97 ... 122).contains($0) || $0 == 45
                    }
            }
    }
}

public struct TicketMetadata: Codable, Sendable {
    public let principal: String
    public let realm: String
    public let cache: String
    public let expires: Int
    public let renewUntil: Int
    public let forwardable: Bool
    public let mode: String

    public init(principal: String, realm: String, cache: String, expires: Int,
                renewUntil: Int, forwardable: Bool, mode: String = "password") {
        self.principal = principal
        self.realm = realm
        self.cache = cache
        self.expires = expires
        self.renewUntil = renewUntil
        self.forwardable = forwardable
        self.mode = mode
    }

    public var valid: Bool {
        Configuration.text(principal) && !principal.isEmpty && Configuration.text(realm)
            && !realm.isEmpty && cache.hasPrefix("API:") && cache.utf8.count <= 256
            && Configuration.text(cache) && expires > 0 && renewUntil >= 0
            && ["password", "passkey"].contains(mode)
    }
}
