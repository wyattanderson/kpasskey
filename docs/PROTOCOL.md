# FreeIPA passkey adapter

## Compatibility boundary

Implement a new MIT client preauthentication plugin for `PA-REDHAT-PASSKEY`
(type 153). Preserve the server's protocol and security semantics. Do not
preserve `macos-passkey`'s command line, helper arguments/stdin/stdout contract,
SSSD naming, source structure, JSON object ownership, or build assumptions.
No SSSD source tree should be needed to build or ship KPasskey.

Implement the plugin's protocol logic and the libfido2 adapter in Swift, with
Swift Testing for fixtures and automated tests, following
[AGENTS.md](../AGENTS.md). The MIT C ABI and the C reference sources below do
not justify a C implementation. Use supported Swift interoperability first;
retain a minimal C/Objective-C shim only where a documented API/ABI limitation
makes it absolutely and functionally necessary. Keep parsing, validation,
state handling, and orchestration in Swift.

The sibling sources are a reference for investigation, particularly:

- `sssd/src/krb5_plugin/passkey/passkey.h`: constants and message structures.
- `passkey_utils.c` and `../common/utils.c`: payload serialization/framing.
- `passkey_clpreauth.c`: client callbacks and FAST behavior.
- `passkey_kdcpreauth.c`: challenge/state checks and server handoff.
- `sssd/src/passkey_child/passkey_child_assert.c`: assertion encoding and verification.
- `macos-passkey/src/passkey_child_get_assert.c`: reduced, working device flow.

The [SSSD design document](https://sssd.io/design-pages/passkey_kerberos.html)
explains the overall architecture but explicitly warns that it may lag current
implementation. Record server versions and validate the actual KDC-side code
and behavior used for our compatibility matrix.

## Wire format observed in the prototype

The preauthentication payload is a `passkey ` prefix followed by JSON with a
terminating NUL included in its length. The JSON envelope has `phase`, `state`
and `data`. Observed phase values are 0/init, 1/challenge and 2/reply. The client
must handle only appropriate phases and reject malformed framing and lengths.

Challenge data contains:

- `domain`: FIDO relying party identifier.
- `credential_id_list`: allowed credential identifiers encoded as Base64.
- `user_verification`: integer policy; define accepted values from the actual
  server protocol rather than assuming it is a libfido2 enum or Boolean.
- `cryptographic_challenge`: Base64-encoded 32-byte client-data hash.

Reply data contains `credential_id`, `cryptographic_challenge`,
`authenticator_data`, `assertion_signature`, and optionally `user_id`.
Binary fields use the server's expected Base64 encoding. Preserve the issued
challenge and opaque state. The old terminal path inserts `ipa_otpd state` as
a constant; KPasskey should return the state actually received and validate
that behavior against the KDC. JSON whitespace/key order need not be identical
if the server parses them; field types, values, framing, and binary encoding do.

`authenticator_data` currently carries the CBOR byte-string representation
provided by `fido_assert_authdata_ptr`, not `fido_assert_authdata_raw_ptr`.
Keep that distinction in fixtures and verifier tests. The cryptographic
challenge is already the hash input expected by this protocol: do not construct
WebAuthn clientDataJSON or hash it again. [libfido2 assertion setters](https://developers.yubico.com/libfido2/Manuals/fido_assert_set_clientdata_hash.html)

Apply input-size/count limits, exact bounded realm comparisons, strict Base64
validation, and explicit cleanup. Authenticate the KDC with PKINIT, require FAST,
and bind both request principal realms to the configured realm. Use the RP ID
from that KDC's protected challenge unchanged, after bounded DNS syntax validation;
there is no local RP override or inference from the realm or server hostname.
Validate the returned authenticator data against the challenge's exact RP hash.

## Minimal plugin responsibilities

- Register the preauthentication type and supported MIT interface version.
- Validate the challenge and request context, then publish a structured
  responder question for the worker to handle.
- Require the mechanism's FAST armor and reject missing/invalid responses.
- Encode the assertion as reply PA-DATA and use the FAST armor key through the
  MIT `set_as_key` callback, preserving the established mechanism's behavior.
- Disable fallback after producing an authenticated request; the worker also
  enforces the requested authentication mode across earlier errors/cancellation.
- Observe MIT callback versioning, memory ownership and per-request lifetimes.

No terminal prompts, helper execution, XPC listener, UI objects, device handles,
or custom Kerberos transport live in the plugin. Its worker-facing responder
schema may be independent of its KDC-facing encoding. Do not require a non-null
terminal prompter when the application supplied a complete responder answer.
Plugin validation failures return application-owned numeric codes defined by
`WireError` in `passkey/Wire.swift`, carried through the existing XPC error code
with status `passkeyInvalid` when MIT preserves the code. MIT preserves
`prep_questions` errors but can wrap `process` errors in `KRB5_PREAUTH_FAILED`.
These codes identify the failed check without logging challenge contents.
Generic MIT `KRB5_PREAUTH_FAILED` means
`authenticationFailed`; only `KRB5_LIBOS_CANTREADPWD` means `unexpectedPrompt`.
See [MIT clpreauth documentation](https://web.mit.edu/kerberos/krb5-latest/doc/plugindev/clpreauth.html)
and the selected release's `clpreauth_plugin.h` for the interface contract.
The bundled loader passes minor 1 while allocating and calling the responder
vtable extension. Follow its PKINIT/SPAKE plugins' major-only initialization
check; callback capabilities are checked separately. The relocation test feeds
synthetic PA-DATA through MIT's real loader to verify this compatibility.

## libfido2 adapter responsibilities

Discover supported devices, let the user choose when necessary, open the
selected device, and prepare RP ID, allow-list, challenge hash, and UP/UV policy.
Collect a PIN only when needed for that device and permit supported onboard UV
where policy allows. Return the selected assertion's credential ID, authdata,
signature, and optional user ID to the worker; the server verifies the proof.

The assertion call is synchronous. Device selection, retry state, cancellation,
deadlines and interaction routing belong around it, on worker execution
resources. Use libfido2's protocol/crypto implementation instead of writing our
own PIN exchange. [libfido2 get-assert API](https://developers.yubico.com/libfido2/Manuals/fido_dev_get_assert.html)

Do not automatically try a PIN on every attached key or repeatedly retry an
invalid PIN. Preserve error distinctions and avoid reducing an explicit UV
requirement to a mere touch. Test multiple matching credentials and absent
optional fields. Avoid extending this milestone into credential enrollment,
authenticator management, or local offline login verification.

## Verification strategy

The implementation is in `passkey/Wire.swift`, `passkey/Plugin.swift`,
`xpc/FIDO.swift` and `xpc/Passkey.swift`. Foundation supplies JSON parsing;
libcbor requires one complete definite byte string for authdata and libfido2
decodes its contents. CryptoKit supplies the local RP hash check. None of these
local checks replaces the KDC's signature verification.

The inspected SSSD `krb5_child.c` maps zero UV to false and nonzero to true;
KPasskey accepts only the documented zero/one policies and rejects other integers.
The challenge hash is exactly 32 bytes, the allow-list has one to 64 distinct
credentials of at most 1 KiB each, state is at most 4 KiB, and the complete framed
message is at most 64 KiB. Base64 must be canonical standard padded Base64.
Reply signatures are bounded to 2 KiB, authdata to 16 KiB, and optional user
handles to 64 bytes. No credential or challenge is logged.

The independently authored fixtures follow `sss_passkeykdc_verify`'s exact
state/challenge checks and `prepare_assert`'s call to `fido_assert_set_authdata`.
Tests decode reply objects through JSONSerialization, separately from production
Codable, and verify synthetic P-256 signatures with `fido_assert_verify`, the
server's upstream verification API. They also check no-armor and null-prompter
plugin behavior. No SSSD code was copied or added to the build dependency graph;
the reference sources establish protocol semantics, not a new source license.
These tests do not substitute for testing the deployed FreeIPA/KDC decoder.
The live compatibility/version matrix remains pending in PLAN.md.

Use synthetic serialization fixtures and negative cases before live tests.
Include independent checks against the KDC-side decoder/verifier so an encoder
and decoder sharing the same mistake cannot falsely establish compatibility.
Keep any reference/oracle tooling outside the shipped dependency graph.

Live acceptance is a TGT obtained with the enrolled security key, stored through
the new MIT build and usable by existing macOS consumers. Record the tested
FreeIPA/Kerberos versions, key model/firmware, UV mode, macOS version and CPU.
Enrollment is initially an external prerequisite; no real credentials or
secret-bearing traces belong in source control.
