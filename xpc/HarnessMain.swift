import Foundation
import KPasskeyClient
import KPasskeyContract

private enum HarnessError: Error { case timeout, rejected }

@main
@MainActor
struct HarnessMain {
  static func main() async {
    do {
      let client = WorkerClient()
      defer { client.disconnect() }
      var events: [Message] = []
      client.onEvent = { event in
        events.append(event)
        print("event \(event.operation) \(event.sequence) \(event.kind) \(event.value)")
      }
      try await client.connect()
      print("connected host=\(getpid()) worker=\(client.workerPID) uid=\(geteuid())")

      func wait(_ operation: String, kind: String, value: String? = nil) async throws -> Message {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
          if let event = events.last(where: {
            $0.operation == operation && $0.kind == kind && (value == nil || $0.value == value)
          }) {
            return event
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessError.timeout
      }

      func start(_ label: String, snapshot: Snapshot = Snapshot()) async throws -> String {
        let id = UUID().uuidString
        let reply = try await client.start(snapshot, operation: id)
        print("start \(label) \(id) \(reply.value)")
        guard reply.value == "ok" else { throw HarnessError.rejected }
        return id
      }

      func complete(_ id: String, automatic: Bool) async throws {
        for (stage, answer) in [("selectKey", "key-1"), ("touch", "continue")] {
          let prompt = try await wait(id, kind: "interaction", value: stage)
          var response = answer
          if !automatic {
            print("\(stage): enter '\(answer)' or 'cancel' (scripted fake; no device access)")
            // Terminal input never blocks the actor that receives events or cancellation.
            var line: String?
            let input = Task { line = await Task.detached { readLine() ?? "cancel" }.value }
            // ponytail: poll only this console prompt; the UI consumes onEvent directly.
            while line == nil
              && !events.contains(where: { $0.operation == id && $0.kind == "terminal" })
            {
              try await Task.sleep(for: .milliseconds(10))
            }
            input.cancel()
            response = line ?? "cancel"
          }
          if response == "cancel" {
            _ = try await client.cancel(id)
            break
          }
          let reply = try await client.respond(to: prompt, value: response)
          print("response \(reply.value)")
          if reply.value != "ok" {
            _ = try await client.cancel(id)
            break
          }
        }
        _ = try await wait(id, kind: "terminal")
      }

      if CommandLine.arguments.contains("--exercise") {
        let unsupported = try await client.exchange(Message("negotiate", version: 999))
        print("unsupported \(unsupported.value)")
        let malformed = try await client.exchange(Message("start", operation: "invalid"))
        print("malformed \(malformed.value)")
        let id = try await start("roundtrip")
        let concurrent = try await client.start(Snapshot())
        print("concurrent \(concurrent.value)")
        let stale = try await client.exchange(
          Message(
            "respond", operation: id,
            interaction: UUID().uuidString, value: "key-1"))
        print("stale \(stale.value)")
        try await complete(id, automatic: true)
        let replay = try await client.start(Snapshot(), operation: id)
        print("replay \(replay.value)")
        try await complete(try await start("repeat"), automatic: true)
        try await complete(
          try await start("failure", snapshot: Snapshot(outcome: "failure")), automatic: true)

        let cancelled = try await start("cancel")
        _ = try await wait(cancelled, kind: "interaction")
        let before = ContinuousClock.now
        let ack = try await client.cancel(cancelled)
        _ = try await wait(cancelled, kind: "terminal")
        print("cancel_ack \(ack.value) bounded=\(before.duration(to: .now) < .seconds(1))")
        let again = try await client.cancel(cancelled)
        print("cancel_again \(again.value)")
        let expired = try await start("deadline", snapshot: Snapshot(timeoutMilliseconds: 200))
        _ = try await wait(expired, kind: "terminal")

        let disconnected = try await start("disconnect")
        client.disconnect()
        _ = try await wait(disconnected, kind: "terminal")
        try await client.connect()
        let killed = try await start("kill")
        // Only the negotiated, signature-verified fake worker is terminated by this test mode.
        guard kill(client.workerPID, SIGKILL) == 0 else { throw HarnessError.rejected }
        _ = try await wait(killed, kind: "terminal")
        try await client.connect()
        try await complete(try await start("reconnect"), automatic: true)
        let invalidArchive = try await start("invalidArchive")
        do {
          _ = try await client.exchange(
            Message("negotiate", value: String(repeating: "x", count: 257)))
          throw HarnessError.rejected
        } catch is ClientFailure {
          print("decode_rejected")
        }
        _ = try await wait(invalidArchive, kind: "terminal")
        try await client.connect()
        try await complete(try await start("afterInvalidArchive"), automatic: true)
        // Give any duplicate terminal callbacks a chance to arrive before the test inspects output.
        try await Task.sleep(for: .milliseconds(250))
        print("exercise complete")
      } else {
        try await complete(
          try await start("interactive"), automatic: CommandLine.arguments.contains("--automatic"))
      }
    } catch {
      // Error categories only. Never print arbitrary remote NSError descriptions.
      let status = (error as? ClientFailure)?.status.rawValue ?? "connectionOrHarnessFailure"
      print("harness_error \(status)")
      exit(1)
    }
  }
}
