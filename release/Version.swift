import Foundation

@main struct Version {
  static func main() {
    do { try execute() }
    catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }

  static func execute() throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else { throw ReleaseError("Run through bazel run //:version, //:bump, or //:pin_actions") }
    let tool = URL(fileURLWithPath: args[1]).standardizedFileURL.path
    let root = URL(fileURLWithPath: try requiredEnvironment("BUILD_WORKSPACE_DIRECTORY"))
    if args[2] == "pin_actions" {
      print(try run(tool, [root.appendingPathComponent(".github/workflows").path]))
      return
    }
    guard try run("/usr/bin/git", ["rev-parse", "--is-shallow-repository"], directory: root) == "false" else {
      throw ReleaseError("Fetch the complete Git history and tags before versioning")
    }
    let current = try run(tool, ["current", "--tag.mode=current"], directory: root)
    _ = try releaseVersion(current)
    if args[2] == "version" {
      guard args.count == 3 else { throw ReleaseError("version takes no arguments") }
      print(current)
      return
    }
    guard args[2] == "bump", args.count <= 4,
      ["next", "major", "minor", "patch"].contains(args.count == 4 ? args[3] : "next") else {
      throw ReleaseError("Usage: bazel run //:bump -- [next|major|minor|patch]")
    }
    guard try run("/usr/bin/git", ["status", "--porcelain"], directory: root).isEmpty else {
      throw ReleaseError("Commit or stash changes before tagging a release")
    }
    let next = try run(tool, [args.count == 4 ? args[3] : "next", "--tag.mode=current"], directory: root)
    _ = try releaseVersion(next)
    guard next != current else { throw ReleaseError("No version bump; use Conventional Commits or request patch/minor/major") }
    try run("/usr/bin/git", ["tag", "-a", next, "-m", "Release \(next)"], directory: root)
    print("Created \(next). Publish with: git push origin \(next)")
  }
}
