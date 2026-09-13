import Foundation

struct ReleaseError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

// Never include arguments or captured output in failures: signing commands carry secrets.
@discardableResult
func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.currentDirectoryURL = directory
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationReason == .exit, process.terminationStatus == 0 else {
    throw ReleaseError("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus))")
  }
  return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func releaseVersion(_ tag: String) throws -> String {
  guard tag.wholeMatch(of: /v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/) != nil else {
    throw ReleaseError("Expected a stable SemVer tag: vMAJOR.MINOR.PATCH")
  }
  return String(tag.dropFirst())
}

func requiredEnvironment(_ name: String) throws -> String {
  guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
    throw ReleaseError("Missing \(name)")
  }
  return value
}
