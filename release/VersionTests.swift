import Foundation
import Testing

@Test func versionBumpUsesSVUAndRejectsUnsafeTags() throws {
  for tag in ["v1.2.3-rc.1", "v01.2.3", "1.2.3", "v1.2.3\n", "v1.2.3/other"] {
    #expect(throws: ReleaseError.self) { try releaseVersion(tag) }
  }
  #expect(try releaseVersion("v1.2.3") == "1.2.3")
  let fm = FileManager.default
  let root = URL(fileURLWithPath: try requiredEnvironment("TEST_TMPDIR")).appendingPathComponent("Version test")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  try run("/usr/bin/git", ["init", "-q", root.path])
  try run("/usr/bin/git", ["config", "user.name", "Release Test"], directory: root)
  try run("/usr/bin/git", ["config", "user.email", "release@example.invalid"], directory: root)
  try run("/usr/bin/git", ["config", "commit.gpgsign", "false"], directory: root)
  try run("/usr/bin/git", ["config", "tag.gpgsign", "false"], directory: root)
  try run("/usr/bin/git", ["commit", "--allow-empty", "-qm", "initial"], directory: root)
  let runfiles = URL(fileURLWithPath: try requiredEnvironment("TEST_SRCDIR"))
    .appendingPathComponent(try requiredEnvironment("TEST_WORKSPACE"))
  let svu = runfiles.appendingPathComponent(try requiredEnvironment("SVU")).standardizedFileURL.path
  let bump = runfiles.appendingPathComponent(try requiredEnvironment("BUMP")).path
  let version = runfiles.appendingPathComponent(try requiredEnvironment("VERSION")).path
  func invoke(_ executable: String, _ command: String, _ extra: [String] = []) throws -> String {
    try run("/usr/bin/env", ["BUILD_WORKSPACE_DIRECTORY=\(root.path)", executable, svu, command] + extra)
  }
  #expect(try invoke(version, "version") == "v0.0.0")
  try run("/usr/bin/git", ["tag", "v1.2.3"], directory: root)
  try run("/usr/bin/git", ["commit", "--allow-empty", "-qm", "feat: new capability"], directory: root)
  #expect(try invoke(bump, "bump").contains("Created v1.3.0"))
  #expect(try invoke(version, "version") == "v1.3.0")
  #expect(throws: ReleaseError.self) { try invoke(bump, "bump") }
  try Data("dirty".utf8).write(to: root.appendingPathComponent("untracked"))
  #expect(throws: ReleaseError.self) { try invoke(bump, "bump", ["patch"]) }
  #expect(try run("/usr/bin/git", ["tag", "--list", "v1.3.1"], directory: root).isEmpty)
}
