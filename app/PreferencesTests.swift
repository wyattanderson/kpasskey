import Foundation
import KPasskeyContract
import Testing

@Test func realmTracksEveryAccountKeystroke() {
  var configuration = Configuration(principal: "wyatt@")
  #expect(configuration.effectiveRealm.isEmpty)
  var realm = ""
  for character in "LAB.WYA.TT" {
    realm.append(character)
    configuration.principal = "wyatt@" + realm
    #expect(configuration.effectiveRealm == realm)
    #expect(configuration.realm.isEmpty)
  }
  configuration.principal = "wyatt@L"
  #expect(configuration.effectiveRealm == "L")
  configuration.principal = "wyatt"
  #expect(configuration.effectiveRealm.isEmpty)
  configuration.realm = "EXPLICIT.REALM"
  #expect(configuration.effectiveRealm == "EXPLICIT.REALM")
}

@Test @MainActor func certificateRealmBindingSurvivesImportsAndAccountEdits() throws {
  let suite = "KPasskeyTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = Preferences(defaults: defaults)
  preferences.configuration.principal = "user@EXAMPLE.ORG"
  let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KPASSKEY_TEST_CA"]))
  let der = try Data(contentsOf: fixture)
  // Bazel runfiles are symlinks; the file picker imports regular files.
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try der.write(to: url)
  preferences.importCertificate(from: url)
  #expect(preferences.configuration.pkinitCA == der)
  #expect(preferences.save())
  let saved = defaults.data(forKey: "configuration")

  let pem = Data(("-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: .lineLength64Characters)
    + "\n-----END CERTIFICATE-----\n").utf8)
  #expect(try Preferences.certificate(pem) == der)
  let imported = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: imported) }
  try pem.write(to: imported)
  preferences.importCertificate(from: imported)
  #expect(preferences.configuration.pkinitCA == der)

  preferences.configuration.principal = "user@OTHER.ORG"
  #expect(!preferences.save())
  #expect(defaults.data(forKey: "configuration") == saved)
  let invalid = try PropertyListEncoder().encode(preferences.configuration)
  #expect(throws: (any Error).self) { try Configuration.load(invalid) }
  try invalid.write(to: imported)
  preferences.configuration.principal = "user@EXAMPLE.ORG"
  preferences.importSettings(from: imported)
  #expect(preferences.configuration.principal == "user@EXAMPLE.ORG")
  #expect(preferences.configuration.pkinitCA == der)

  preferences.configuration.principal = "user@OTHER.ORG"
  preferences.configuration.pkinitCA = Data()
  preferences.importCertificate(from: url)
  #expect(preferences.configuration.pkinitCA.isEmpty)
  #expect(preferences.notice.contains("Organization (O)"))
}

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
