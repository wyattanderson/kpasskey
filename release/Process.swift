import Foundation

struct ReleaseError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

// Never include arguments. Output is opt-in because credential commands can echo secrets.
@discardableResult
func run(_ executable: String, _ arguments: [String], directory: URL? = nil, reportOutput: Bool = false) throws -> String {
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
  let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  guard process.terminationReason == .exit, process.terminationStatus == 0 else {
    throw ReleaseError("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus))"
      + (reportOutput ? ": \(message)" : ""))
  }
  return message
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
