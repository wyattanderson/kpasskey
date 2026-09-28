import CFIDO2
import Foundation
import KPasskeyContract

public struct DiscoveredKey: Sendable {
    public let path: String
    public let key: SecurityKey
    let identified: Bool
}

/// Enumerating does not open devices; metadata reads happen once per attachment, while idle.
public func discoverKeys(previous: [DiscoveredKey], enrich: Bool) throws -> [DiscoveredKey] {
    fido_init(0)
    var manifest = fido_dev_info_new(16)
    guard let list = manifest else { throw KerberosFailure(.deviceFailure) }
    defer { fido_dev_info_free(&manifest, 16) }
    var count = 0
    guard fido_dev_info_manifest(list, 16, &count) == FIDO_OK else {
        throw KerberosFailure(.deviceFailure)
    }
    let metadataDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    return (0 ..< count).compactMap { index in
        let info = fido_dev_info_ptr(list, index)
        guard let rawPath = fido_dev_info_path(info) else { return nil }
        let path = String(cString: rawPath)
        let cached = previous.first { $0.path == path }
        if let cached, cached.identified || !enrich {
            return cached
        }
        let manufacturer = fido_dev_info_manufacturer_string(info).map { String(cString: $0) } ?? ""
        let product = fido_dev_info_product_string(info).map { String(cString: $0) } ?? ""
        let label = SecurityKey.label(manufacturer: manufacturer, product: product)
        let yubico = fido_dev_info_vendor(info) == 0x1050
        let identify = enrich && ContinuousClock.now < metadataDeadline
        let identity = identify && yubico ? readYubiKeyIdentity(
            path: path,
            productID: UInt16(bitPattern: fido_dev_info_product(info))
        ) : nil
        return DiscoveredKey(path: path,
                             key: SecurityKey(id: cached?.key.id ?? UUID().uuidString,
                                              name: identity?.name ?? label, icon: identity?.icon),
                             identified: identify || !yubico)
    }.sorted { $0.path < $1.path }
}

private func readYubiKeyIdentity(path: String, productID: UInt16) -> (name: String, icon: String?)? {
    var device = fido_dev_new()
    guard let dev = device else { return nil }
    defer { fido_dev_free(&device) }
    guard fido_dev_set_timeout(dev, 250) == FIDO_OK, fido_dev_open(dev, path) == FIDO_OK else { return nil }
    defer { fido_dev_close(dev) }
    guard fido_dev_is_fido2(dev) else { return nil }
    var page: UInt8 = 0
    var timeout: Int32 = 250
    // Yubico's read-only CTAPHID_READ_CONFIG. libfido2 owns channel IDs and HID framing.
    guard fido_tx(dev, 0x42, &page, 1, &timeout) == 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: 256)
    let length = bytes.withUnsafeMutableBytes { fido_rx(dev, 0x42, $0.baseAddress, $0.count, &timeout) }
    guard length > 0 else { return nil }
    return yubiKeyIdentity(Data(bytes.prefix(Int(length))), productID: productID)
}

/// Naming derived from Yubico yubikit/support.py; icon mapping from yubioath-flutter.
/// See third_party/licenses/YUBICO-NOTICE.txt for upstream attribution and licenses.
public func yubiKeyIdentity(_ encoded: Data, productID: UInt16) -> (name: String, icon: String?)? {
    let bytes = Array(encoded)
    guard let length = bytes.first, Int(length) == bytes.count - 1 else { return nil }
    var fields: [UInt8: [UInt8]] = [:]
    var offset = 1
    while offset < bytes.count {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset], count = Int(bytes[offset + 1])
        offset += 2
        guard offset + count <= bytes.count, fields[tag] == nil else { return nil }
        fields[tag] = Array(bytes[offset ..< (offset + count)])
        offset += count
    }
    guard let form = fields[0x04], form.count == 1,
          let version = fields[0x05], version.count == 3,
          let supported = fields[0x01], (1 ... 2).contains(supported.count)
    else { return nil }
    let factor = form[0] & 0x0F
    let nfc = fields[0x0D] != nil
    let icons: [UInt8: String] = [1: nfc ? "yk5nfc" : "yk4", 2: "yk5nano",
                                  3: nfc ? "yk5cnfc" : "yk5c", 4: "yk5cnano", 5: "yk5ci", 6: "ykbioa", 7: "ykbioc"]
    let capabilities = supported.reduce(0) { ($0 << 8) | Int($1) }
    if productID == 0x0120 {
        guard capabilities & 0x200 != 0 else { return nil }
        return (nfc ? "Security Key NFC" : "Security Key by Yubico", nfc ? "sky3" : "sky2")
    }
    // Unknown generations/forms retain their USB label instead of inventing a model.
    guard (1 ... 7).contains(factor), version[0] == 5, version[1] >= 1 else { return nil }
    let sky = form[0] & 0x40 != 0
    let bio = factor == 6 || factor == 7
    var parts = [sky ? "Security Key" : bio ? "YubiKey" : "YubiKey 5"]
    if [3, 4, 7].contains(factor) {
        parts.append("C")
    } else if factor == 5 {
        parts.append("Ci")
    }
    if factor == 2 || factor == 4 {
        parts.append("Nano")
    } else if nfc {
        parts.append("NFC")
    } else if factor == 1 {
        parts.append("A")
    } else if bio {
        parts.append("Bio")
    }
    if form[0] & 0x80 != 0 {
        parts.append("FIPS")
    } else if bio {
        if capabilities & ~0x202 == 0 {
            parts.append("- FIDO Edition")
        } else if capabilities & 0x10 != 0 {
            parts.append("- Multi-protocol Edition")
        }
    } else if sky, fields[0x02]?.contains(where: { $0 != 0 }) == true {
        parts.append("- Enterprise Edition")
    } else if !sky, fields[0x16] == [1] {
        parts.append("- Enhanced PIN")
    }
    let name = parts.joined(separator: " ").replacingOccurrences(of: "5 C", with: "5C")
        .replacingOccurrences(of: "5 A", with: "5A")
    let namedIcons = ["Security Key NFC": "sky3", "Security Key C NFC": "skycnfc"]
    return (name, namedIcons[name] ?? icons[factor])
}
