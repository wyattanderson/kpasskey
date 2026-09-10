import Foundation
import KPasskeyContract
import Observation
import Security

@MainActor @Observable
final class Preferences {
  var configuration = Configuration(principal: "") {
    didSet { apply() }
  }
  var notice = ""
  private let defaults: UserDefaults
  private static let key = "configuration"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    configuration.mode = .passkey
    if let saved = defaults.data(forKey: Self.key) {
      do { configuration = try Configuration.load(saved) }
      catch { notice = "Settings couldn’t be read. Review your settings." }
    }
  }

  @discardableResult
  func validate() -> Bool {
    guard configuration.valid else {
      notice = "Enter a valid account and realm. Security key sign-in also needs a KDC CA certificate."
      return false
    }
    guard configuration.mode != .passkey || configuration.validPKINITCA else {
      notice = "Choose a valid KDC CA certificate whose subject Organization (O) exactly matches the realm."
      return false
    }
    notice = ""
    return true
  }

  private func apply() {
    guard validate() else { return }
    do {
      defaults.set(try PropertyListEncoder().encode(configuration), forKey: Self.key)
    } catch { notice = "Settings couldn’t be retained. Try changing them again." }
  }

  func importSettings(from url: URL) {
    do {
      configuration = try Configuration.load(Self.read(url, limit: 8192))
    } catch {
      notice = "Choose a valid KPasskey settings plist without passwords or PINs. For security key sign-in, the CA subject Organization (O) must exactly match the realm."
    }
  }

  func importCertificate(from url: URL) {
    do {
      var candidate = configuration
      candidate.pkinitCA = try Self.certificate(Self.read(url, limit: 8192))
      guard candidate.validPKINITCA else { throw CocoaError(.coderInvalidValue) }
      configuration.pkinitCA = candidate.pkinitCA
    } catch {
      notice = "Choose a valid PEM or DER KDC CA certificate whose subject Organization (O) exactly matches the realm."
    }
  }

  static func certificate(_ bytes: Data) throws -> Data {
    guard bytes.count <= 8192 else { throw CocoaError(.coderInvalidValue) }
    var der = bytes
    if let pem = String(data: bytes, encoding: .utf8), pem.hasPrefix("-----BEGIN CERTIFICATE-----") {
      let body = pem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
        .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        .components(separatedBy: .whitespacesAndNewlines).joined()
      guard let decoded = Data(base64Encoded: body) else { throw CocoaError(.coderInvalidValue) }
      der = decoded
    }
    guard (1...4096).contains(der.count), SecCertificateCreateWithData(nil, der as CFData) != nil
    else { throw CocoaError(.coderInvalidValue) }
    return der
  }

  private static func read(_ url: URL, limit: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= limit else {
      throw CocoaError(.fileReadTooLarge)
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let bytes = try file.read(upToCount: limit + 1) ?? Data()
    guard bytes.count <= limit else { throw CocoaError(.fileReadTooLarge) }
    return bytes
  }
}
