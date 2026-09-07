import Foundation

public struct BuildTestFailure: Error, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

public func environment(_ name: String) throws -> String {
  guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
    throw BuildTestFailure("Missing environment variable: \(name)")
  }
  return value
}

public func runfile(_ path: String) throws -> URL {
  URL(fileURLWithPath: try environment("TEST_SRCDIR"))
    .appendingPathComponent(try environment("TEST_WORKSPACE"))
    .appendingPathComponent(path)
}

public func artifact(_ name: String) throws -> URL {
  try runfile(environment(name))
}

@discardableResult
public func run(
  _ executable: String, _ arguments: [String] = [],
  environment: [String: String]? = nil, directory: URL? = nil
) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = environment
  process.currentDirectoryURL = directory
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  // Drain before waiting: otool can produce more than a pipe buffer for archives.
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let output = String(decoding: data, as: UTF8.self)
  guard process.terminationReason == .exit && process.terminationStatus == 0 else {
    throw BuildTestFailure(
      "\(executable) \(arguments) failed (\(process.terminationStatus)):\n\(output)")
  }
  return output
}

public func dylibs(in tree: URL) throws -> [URL] {
  let files = try FileManager.default.contentsOfDirectory(
    at: tree.appendingPathComponent("lib"), includingPropertiesForKeys: nil
  )
  .filter { $0.pathExtension == "dylib" }
  guard !files.isEmpty else { throw BuildTestFailure("No dylibs in \(tree.path)") }
  return files.sorted { $0.path < $1.path }
}

public func dependencies(of artifact: URL) throws -> [String] {
  try run("/usr/bin/otool", ["-L", artifact.path]).split(separator: "\n").dropFirst().map {
    String($0).trimmingCharacters(in: .whitespaces)
      .components(separatedBy: " (compatibility version")[0]
  }
}

public func rpaths(of artifact: URL) throws -> [String] {
  let output = try run("/usr/bin/otool", ["-l", artifact.path])
  var isRpath = false
  var result: [String] = []
  for line in output.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("cmd ") { isRpath = trimmed == "cmd LC_RPATH" }
    if isRpath && trimmed.hasPrefix("path ") {
      result.append(String(trimmed.dropFirst(5)).components(separatedBy: " (offset")[0])
    }
  }
  return result
}

public func minimumOSVersions(of artifact: URL) throws -> [String] {
  try run("/usr/bin/otool", ["-l", artifact.path]).split(separator: "\n").compactMap {
    let fields = $0.split(whereSeparator: \.isWhitespace)
    return fields.count == 2 && fields[0] == "minos" ? String(fields[1]) : nil
  }
}
