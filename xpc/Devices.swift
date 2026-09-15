import Foundation

/// Presentation only. The opaque ID resolves to a device path inside this worker connection.
public struct SecurityKey: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let icon: String?

  public static let icons: Set<String> = [
    "sky2", "sky3", "skycnfc", "yk4", "yk5nano", "yk5c", "yk5cnano", "yk5ci",
    "ykbioa", "ykbioc", "yk5nfc", "yk5cnfc",
  ]

  public init(id: String, name: String, icon: String? = nil) {
    self.id = id
    self.name = name
    self.icon = icon
  }

  public var valid: Bool {
    UUID(uuidString: id)?.uuidString == id && !name.isEmpty && name.utf8.count <= 128
      && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0)
        && $0.properties.generalCategory != .format }
      && (icon.map { Self.icons.contains($0) } ?? true)
  }

  public static func label(manufacturer: String, product: String) -> String {
    let scalars = (manufacturer + " " + product).unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
    }
    let text = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    var label = ""
    for scalar in text.unicodeScalars {
      guard label.utf8.count + scalar.utf8.count <= 128 else { break }
      label.unicodeScalars.append(scalar)
    }
    return label.isEmpty ? "FIDO security key" : label
  }
}
