import CMITKerberos
import Foundation
import PasskeyPlugin
import PasskeyWire
import Testing

@Test func pluginABIAndMissingArmorFailClosed() throws {
    var vtable = krb5_clpreauth_vtable_st()
    try withUnsafeMutablePointer(to: &vtable) { table in
        let opaque = OpaquePointer(table)
        #expect(initializePlugin(nil, 2, 2, opaque) == Int32(KRB5_PLUGIN_VER_NOTSUPP))
        #expect(initializePlugin(nil, 1, 1, opaque) == 0)
        #expect(initializePlugin(nil, 1, 2, opaque) == 0)
        #expect(try String(cString: #require(table.pointee.name)) == "kpasskey")
        #expect(table.pointee.pa_type_list[0] == 153 && table.pointee.pa_type_list[1] == 0)
        let prep = try #require(table.pointee.prep_questions)
        let process = try #require(table.pointee.process)
        for version: Int32 in [1, 2, 3] {
            var callbackTable = krb5_clpreauth_callbacks_st()
            callbackTable.vers = version
            #expect(prep(nil, nil, nil, nil, &callbackTable, nil, nil, nil, nil, nil) != 0)
            var output: UnsafeMutablePointer<UnsafeMutablePointer<krb5_pa_data>?>?
            #expect(process(nil, nil, nil, nil, &callbackTable, nil, nil, nil, nil, nil, nil, nil, &output) != 0)
            #expect(output == nil)
        }
    }
}

private final class Callbacks {
    var question: Data?
    var answer: UnsafeMutablePointer<CChar>?
    let armor = UnsafeMutablePointer<krb5_keyblock>.allocate(capacity: 1)
    var keySet = false
    var fallbackDisabled = false

    init() {
        armor.initialize(to: krb5_keyblock())
    }

    deinit {
        free(answer)
        armor.deallocate()
    }

    static func get(_ rock: krb5_clpreauth_rock?) -> Callbacks {
        Unmanaged<Callbacks>.fromOpaque(UnsafeRawPointer(rock!)).takeUnretainedValue()
    }
}

@Test(arguments: ["example.org", "login.other.net", "EXAMPLE.ORG"])
func responderPluginPreservesKDCProvidedRPAndRejectsRealmAndReplay(domain: String) throws {
    var profile: profile_t?
    #expect(profile_init(nil, &profile) == 0)
    let profileHandle = try #require(profile)
    defer { profile_abandon(profileHandle) }

    let strings = try [#require(strdup("kpasskey")), #require(strdup("realm"))]
    defer { strings.forEach { free($0) } }
    var names = strings.map { Optional(UnsafePointer($0)) } + [nil]
    #expect(profile_add_relation(profileHandle, &names, "EXAMPLE.ORG") == 0)

    var context: krb5_context?
    #expect(krb5_init_context_profile(profileHandle, KRB5_INIT_CONTEXT_SECURE, &context) == 0)
    let ctx = try #require(context)
    defer { krb5_free_context(ctx) }

    var client: krb5_principal?
    var server: krb5_principal?
    #expect(krb5_parse_name(ctx, "user@EXAMPLE.ORG", &client) == 0)
    #expect(krb5_parse_name(ctx, "krbtgt/EXAMPLE.ORG@EXAMPLE.ORG", &server) == 0)
    defer {
        krb5_free_principal(ctx, client)
        krb5_free_principal(ctx, server)
    }

    var request = krb5_kdc_req()
    request.client = client
    request.server = server

    let state = Callbacks()
    let rock = OpaquePointer(Unmanaged.passUnretained(state).toOpaque())
    var callbacks = krb5_clpreauth_callbacks_st()
    callbacks.vers = 3
    callbacks.fast_armor = { _, rock in Callbacks.get(rock).armor }
    callbacks.ask_responder_question = { _, rock, name, value in
        guard String(cString: name!) == passkeyQuestion, let value else { return EINVAL }
        Callbacks.get(rock).question = try? responderBytes(value)
        return 0
    }
    callbacks.get_responder_answer = { _, rock, _ in Callbacks.get(rock).answer.map { UnsafePointer($0) } }
    callbacks.set_as_key = { _, rock, _ in
        Callbacks.get(rock).keySet = true
        return 0
    }
    callbacks.disable_fallback = { _, rock in Callbacks.get(rock).fallbackDisabled = true }

    var vtable = krb5_clpreauth_vtable_st()
    #expect(withUnsafeMutablePointer(to: &vtable) { initializePlugin(ctx, 1, 1, OpaquePointer($0)) } == 0)
    let prep = try #require(vtable.prep_questions)
    let process = try #require(vtable.process)

    let challenge = try challengeFixture(["domain": domain])
    try challenge.withUnsafeBytes { bytes in
        var preauthData = krb5_pa_data()
        preauthData.pa_type = 153
        preauthData.length = UInt32(bytes.count)
        preauthData.contents = UnsafeMutablePointer(mutating: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))

        #expect(prep(ctx, nil, nil, nil, &callbacks, rock, &request, nil, nil, &preauthData) == 0)
        let question = try #require(state.question)
        let original = try decodeWire(question, as: Challenge.self, phase: 1)
        #expect(original.data.domain.utf8.elementsEqual(domain.utf8))
        #expect(original.state == "opaque-state-é")

        // strcmp at the KDC distinguishes composed/decomposed Unicode even when Swift == does not.
        for replyState in ["stale-state", "opaque-state-e\u{301}", original.state] {
            let valid = replyState.utf8.elementsEqual(original.state.utf8)
            let reply = try encodeWire(Envelope(phase: 2, state: replyState, data: fixtureAssertion(domain: domain)))
            free(state.answer)
            state.answer = reply.withUnsafeBytes { strdup($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            var output: UnsafeMutablePointer<UnsafeMutablePointer<krb5_pa_data>?>?
            let code = process(
                ctx, nil, nil, nil, &callbacks, rock, &request, nil, nil, &preauthData, nil, nil, &output
            )
            defer {
                if let item = output?.pointee {
                    free(item.pointee.contents)
                    free(item)
                }
                free(output)
            }

            #expect((code == 0) == valid)
            #expect(state.keySet == valid && state.fallbackDisabled == valid)
            if valid {
                #expect(output?[1] == nil)
                let item = try #require(output?.pointee)
                #expect(item.pointee.pa_type == 153)
                let bytes = Data(bytes: item.pointee.contents, count: Int(item.pointee.length))
                let actual = try decodeWire(bytes, as: Assertion.self, phase: 2)
                #expect(actual.state.utf8.elementsEqual(replyState.utf8))
                // JSON object key order is not part of the protocol.
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                #expect(try encoder.encode(actual.data) == encoder.encode(fixtureAssertion(domain: domain)))
            } else {
                #expect(output == nil)
            }
        }

        // A prefix match is insufficient: the request's realm must match in full.
        var other: krb5_principal?
        #expect(krb5_parse_name(ctx, "user@EXAMPLE.ORG.EVIL", &other) == 0)
        defer { krb5_free_principal(ctx, other) }
        request.client = other
        #expect(prep(ctx, nil, nil, nil, &callbacks, rock, &request, nil, nil, &preauthData) ==
            WireError.realmMismatch.rawValue)
        request.client = client
    }

    // Preserve the failing check across the plugin ABI without exposing payloads.
    for (bytes, error): (Data, WireError) in try [
        (Data(challenge.dropLast()), .framing),
        (Data("passkey {}\0".utf8), .json),
        (challengeFixture(phase: 2), .phase),
        (challengeFixture(["domain": "example.org\0.evil"]), .rpInvalid),
        (challengeFixture(["user_verification": 2]), .uvPolicy),
        (challengeFixture(["cryptographic_challenge": "AA=="]), .challengeHash)
    ] {
        bytes.withUnsafeBytes { buffer in
            var preauthData = krb5_pa_data()
            preauthData.pa_type = 153
            preauthData.length = UInt32(buffer.count)
            preauthData.contents = UnsafeMutablePointer(
                mutating: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            )

            state.question = nil
            #expect(prep(ctx, nil, nil, nil, &callbacks, rock, &request, nil, nil, &preauthData) == error.rawValue)
            #expect(state.question == nil)
        }
    }
}
