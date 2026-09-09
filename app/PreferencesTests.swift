import Foundation
import KPasskeyContract
import Testing

@Test @MainActor func settingsRoundTripAndInvalidDataLeaveSavedAccountIntact() throws {
  let suite = "KPasskeyTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = Preferences(defaults: defaults)
  #expect(preferences.configuration.principal.isEmpty)
  #expect(!preferences.save())
  preferences.configuration = Configuration(principal: "user@EXAMPLE.INVALID")
  #expect(preferences.save())
  preferences.configuration.principal = ""
  #expect(!preferences.save())
  let restored = Preferences(defaults: defaults)
  #expect(restored.configuration.principal == "user@EXAMPLE.INVALID")
  let bytes = try #require(defaults.data(forKey: "configuration"))
  let values = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
  #expect(values["password"] == nil && values["pin"] == nil)
  #expect(throws: (any Error).self) { try Preferences.certificate(Data("not a certificate".utf8)) }
  #expect(throws: (any Error).self) { try Preferences.certificate(Data(repeating: 65, count: 8193)) }
  defaults.set(Data("invalid".utf8), forKey: "configuration")
  let invalid = Preferences(defaults: defaults)
  #expect(!invalid.notice.isEmpty)
  #expect(invalid.configuration.principal.isEmpty)
}
