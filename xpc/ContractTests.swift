import Foundation
import KPasskeyContract
import KPasskeyWorker
import Security
import Testing

@Test @MainActor func deviceInventoryIsBoundedAndSelectionIsConnectionScoped() throws {
    let key = SecurityKey(id: UUID().uuidString, name: "Security Key NFC", icon: "sky3")
    let message = Message("devices", devices: [key])
    let data = try NSKeyedArchiver.archivedData(withRootObject: message, requiringSecureCoding: true)
    let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: data))
    #expect(decoded.devices == [key])
    #expect(!Message("devices", devices: [key, key]).bounded)
    #expect(!message.validCommand)
    #expect(Message("devices").validCommand)
    #expect(!Message("devices", value: "/dev/arbitrary").validCommand)
    var configuration = Configuration(principal: "user@EXAMPLE.ORG")
    configuration.mode = .passkey
    configuration.pkinitCA = Data([1])
    let snapshot = Snapshot(configuration: configuration, selectedDevice: key.id)
    let snapshotData = try NSKeyedArchiver.archivedData(withRootObject: snapshot, requiringSecureCoding: true)
    #expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: Snapshot.self, from: snapshotData)?.selectedDevice == key
        .id)
    #expect(!Snapshot(configuration: configuration, selectedDevice: "/dev/arbitrary").valid)
    let session = WorkerSession { _ in }
    _ = session.handle(Message("negotiate"))
    #expect(session.handle(Message("start", operation: UUID().uuidString, snapshot: snapshot)).value == "deviceRemoved")
    session.disconnect()
}

@Test func secureCodingAndValidation() throws {
    let original = Message("start", operation: UUID().uuidString, snapshot: Snapshot())
    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try #require(
        try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: data)
    )
    #expect(decoded.validCommand)
    #expect(decoded.snapshot?.principal == "demo")
    let prompt = Message(
        "interaction", operation: UUID().uuidString, interaction: UUID().uuidString,
        value: "selectKey", sequence: 2, remainingMilliseconds: 500
    )
    let promptData = try NSKeyedArchiver.archivedData(
        withRootObject: prompt, requiringSecureCoding: true
    )
    #expect(
        try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: promptData)?
            .remainingMilliseconds == 500
    )
    #expect(!Message("start", operation: "bad", snapshot: Snapshot()).validCommand)
    #expect(
        !Message("start", operation: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", snapshot: Snapshot())
            .validCommand
    )
    #expect(!Message("cancel", operation: UUID().uuidString, value: "unexpected").validCommand)
    #expect(!Message("unknown").validCommand)
    #expect(!Message("negotiate", value: String(repeating: "x", count: 257)).bounded)
    #expect(!Snapshot(schema: 2).valid)
    #expect(!Snapshot(principal: "bad\nname").valid)
    #expect(!Snapshot(timeoutMilliseconds: 0).valid)
    #expect(!Snapshot(outcome: "password").valid)
    // Decoding an unexpected root type is rejected, not interpreted as a message.
    let foreign = try NSKeyedArchiver.archivedData(
        withRootObject: NSDate(), requiringSecureCoding: true
    )
    #expect(throws: (any Error).self) {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: Message.self, from: foreign)
    }
}

@Test(arguments: [true, false]) @MainActor
func cancellationCompletionRace(cancelFirst: Bool) async throws {
    var events: [Message] = []
    let session = WorkerSession { events.append($0) }
    _ = session.handle(Message("negotiate"))
    let id = UUID().uuidString
    _ = session.handle(Message("start", operation: id, snapshot: Snapshot(timeoutMilliseconds: 200)))
    _ = try session.handle(
        Message(
            "respond", operation: id, interaction: #require(events.last).interaction,
            value: "key-1"
        )
    )
    let finish = try Message(
        "respond", operation: id, interaction: #require(events.last).interaction,
        value: "continue"
    )
    let cancel = Message("cancel", operation: id)
    for command in cancelFirst ? [cancel, finish] : [finish, cancel] {
        _ = session.handle(command)
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(
        events.filter { $0.kind == "terminal" }.map(\.value) == [cancelFirst ? "cancelled" : "ok"]
    )
}

@Test @MainActor func workerLifecycle() async throws {
    var events: [Message] = []
    let session = WorkerSession { events.append($0) }
    let id = UUID().uuidString
    let start = Message("start", operation: id, snapshot: Snapshot(timeoutMilliseconds: 200))
    #expect(session.handle(start).value == "protocolViolation")
    #expect(session.handle(Message("negotiate", version: 1)).value == "unsupportedVersion")
    #expect(session.handle(Message("negotiate")).kind == "negotiated")
    #expect(session.handle(start).value == "ok")
    #expect(session.handle(start).value == "busy")
    let prompt = try #require(events.last)
    #expect(
        session.handle(
            Message(
                "respond", operation: id, interaction: UUID().uuidString,
                value: "key-1"
            )
        ).value == "staleInteraction"
    )
    #expect(
        session.handle(
            Message(
                "respond", operation: id, interaction: prompt.interaction,
                value: "continue"
            )
        ).value == "protocolViolation"
    )
    #expect(
        session.handle(
            Message(
                "respond", operation: id, interaction: prompt.interaction,
                value: "key-1"
            )
        ).value == "ok"
    )
    #expect(
        session.handle(
            Message(
                "respond", operation: id, interaction: prompt.interaction,
                value: "key-1"
            )
        ).value == "staleInteraction"
    )
    let touch = try #require(events.last)
    #expect(
        session.handle(
            Message(
                "respond", operation: id, interaction: touch.interaction,
                value: "continue"
            )
        ).value == "ok"
    )
    #expect(session.handle(Message("cancel", operation: id)).value == "ok")
    #expect(session.handle(start).value == "protocolViolation")
    #expect(events.map(\.sequence) == [1, 2, 3, 4])
    #expect(events.filter { $0.kind == "terminal" }.map(\.value) == ["ok"])
    for outcome in ["cancelled", "deadlineExceeded", "disconnected"] {
        events.removeAll()
        let operation = UUID().uuidString
        #expect(
            session.handle(
                Message(
                    "start", operation: operation,
                    snapshot: Snapshot(timeoutMilliseconds: 200)
                )
            ).value == "ok"
        )
        if outcome == "cancelled" {
            _ = session.handle(Message("cancel", operation: operation))
        }
        if outcome == "disconnected" {
            session.disconnect()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            events.filter { $0.kind == "terminal" }.map(\.value)
                == (outcome == "disconnected" ? [] : [outcome])
        )
    }
    #expect(session.handle(Message("negotiate")).value == "protocolViolation")
}

@Test func releasePolicyRejectsAdHocAndUntrustedValues() throws {
    let expression = try PeerPolicy.releaseRequirement(team: "ABCDEFGHIJ", identifier: hostIdentifier)
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess)
    var code: SecCode?
    #expect(SecCodeCopySelf([], &code) == errSecSuccess)
    let currentCode = try #require(code)
    let requiredIdentity = try #require(requirement)
    #expect(SecCodeCheckValidity(currentCode, [], requiredIdentity) != errSecSuccess)
    for identifier in [applicationIdentifier, applicationWorkerIdentifier] {
        let expression = try PeerPolicy.releaseRequirement(team: "ABCDEFGHIJ", identifier: identifier)
        #expect(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess)
        let nativeRequirement = try #require(requirement)
        #expect(SecCodeCheckValidity(currentCode, [], nativeRequirement) != errSecSuccess)
    }
    #expect(throws: PeerPolicyError.self) {
        try PeerPolicy.releaseRequirement(team: "\" or true", identifier: hostIdentifier)
    }
    #expect(throws: PeerPolicyError.self) {
        try PeerPolicy.releaseRequirement(team: "ABCDEFGHIJ", identifier: "attacker")
    }
}
