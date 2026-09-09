import CMITKerberos
import Foundation
import PasskeyWire

// Immutable C storage lives as long as this loaded module's vtable.
private final class Registration: @unchecked Sendable {
  let name = strdup("kpasskey")!
  let types = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
  init() { types.initialize(repeating: 0, count: 2); types[0] = 153 }
  deinit { free(name); types.deallocate() }
}
private let registration = Registration()

private func challenge(_ context: krb5_context?, _ request: UnsafeMutablePointer<krb5_kdc_req>?,
                       _ pa: UnsafeMutablePointer<krb5_pa_data>?) throws -> Envelope<Challenge> {
  guard let context, let request, let client = request.pointee.client,
    let server = request.pointee.server, let pa, pa.pointee.pa_type == 153,
    pa.pointee.length <= maximumWireSize, let contents = pa.pointee.contents
  else { throw WireError.invalid }
  let result = try decodeWire(Data(bytes: contents, count: Int(pa.pointee.length)), as: Challenge.self, phase: 1)
  var profile: profile_t?
  guard krb5_get_profile(context, &profile) == 0, let profile else { throw WireError.configuration }
  defer { profile_release(profile) }
  func setting(_ key: String) throws -> String {
    var value: UnsafeMutablePointer<CChar>?
    guard profile_get_string(profile, "kpasskey", key, nil, nil, &value) == 0, let value
    else { throw WireError.configuration }
    defer { profile_release_string(value) }
    return String(cString: value)
  }
  let realm = try setting("realm")
  for principal in [client, server] {
    let data = principal.pointee.realm
    guard let pointer = data.data, Data(bytes: pointer, count: Int(data.length)) == Data(realm.utf8)
    else { throw WireError.realmMismatch }
  }
  try result.data.validate(rp: setting("rp"))
  return result
}

@_cdecl("clpreauth_kpasskey_initvt")
public func initializePlugin(_ context: krb5_context?, _ major: Int32, _ minor: Int32,
                             _ table: krb5_plugin_vtable?) -> Int32 {
  // The bundled MIT loader passes minor 1 despite allocating and using
  // prep_questions. Match its PKINIT/SPAKE plugins' major-only check; this
  // module is built and shipped with that runtime, not arbitrary older hosts.
  guard major == 1, let table else { return Int32(KRB5_PLUGIN_VER_NOTSUPP) }
  let vt = UnsafeMutableRawPointer(table).assumingMemoryBound(to: krb5_clpreauth_vtable_st.self)
  vt.pointee.name = UnsafePointer(registration.name)
  vt.pointee.pa_type_list = registration.types
  vt.pointee.prep_questions = { context, _, _, _, callbacks, rock, request, _, _, pa in
    guard let cb = callbacks, cb.pointee.vers >= 3,
      let ask = cb.pointee.ask_responder_question else { return WireError.callbacks.rawValue }
    guard cb.pointee.fast_armor?(context, rock) != nil else { return WireError.armor.rawValue }
    do {
      let message = try challenge(context, request, pa)
      let bytes = try encodeWire(message)
      return bytes.withUnsafeBytes {
        ask(context, rock, passkeyQuestion, $0.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
    } catch { return ((error as? WireError) ?? .invalid).rawValue }
  }
  vt.pointee.process = { context, _, _, _, callbacks, rock, request, _, _, pa, _, _, output in
    output?.pointee = nil
    guard let cb = callbacks, cb.pointee.vers >= 3, let output,
      let armor = cb.pointee.fast_armor?(context, rock),
      let answer = cb.pointee.get_responder_answer?(context, rock, passkeyQuestion),
      let setKey = cb.pointee.set_as_key, let disable = cb.pointee.disable_fallback
    else { return Int32(KRB5_PREAUTH_FAILED) }
    do {
      let input = try challenge(context, request, pa)
      let reply = try decodeWire(responderBytes(answer), as: Assertion.self, phase: 2)
      guard reply.state.utf8.elementsEqual(input.state.utf8) else { throw WireError.state }
      try reply.data.validate(challenge: input.data)
      let bytes = try encodeWire(reply)
      // MIT frees PA-DATA with free(), so these allocations use its C allocator ABI.
      guard let listMemory = calloc(2, MemoryLayout<UnsafeMutablePointer<krb5_pa_data>?>.stride)
      else { return ENOMEM }
      guard let paMemory = calloc(1, MemoryLayout<krb5_pa_data>.stride) else { free(listMemory); return ENOMEM }
      guard let body = malloc(bytes.count) else { free(paMemory); free(listMemory); return ENOMEM }
      var transferred = false
      defer { if !transferred { free(body); free(paMemory); free(listMemory) } }
      bytes.copyBytes(to: body.assumingMemoryBound(to: UInt8.self), count: bytes.count)
      let item = paMemory.assumingMemoryBound(to: krb5_pa_data.self)
      item.pointee.pa_type = 153
      item.pointee.length = UInt32(bytes.count)
      item.pointee.contents = body.assumingMemoryBound(to: UInt8.self)
      let list = listMemory.assumingMemoryBound(to: UnsafeMutablePointer<krb5_pa_data>?.self)
      list[0] = item
      disable(context, rock)
      let code = setKey(context, rock, armor)
      guard code == 0 else { return code }
      output.pointee = list
      transferred = true
      return 0
    } catch { return ((error as? WireError) ?? .invalid).rawValue }
  }
  return 0
}
