# FreeIPA passkey adapter

## Compatibility boundary

Implement a new MIT client preauthentication plugin for `PA-REDHAT-PASSKEY`
(type 153). Preserve the server's protocol and security semantics. Do not
preserve `macos-passkey`'s command line, helper arguments/stdin/stdout contract,
SSSD naming, source structure, JSON object ownership, or build assumptions.
No SSSD source tree should be needed to build or ship KPasskey.

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
validation, and explicit cleanup. Preserve the existing realm/RP binding intent
while making its configuration application-owned. A server-provided domain
must not become authorization to authenticate to an unrelated RP.

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
See [MIT clpreauth documentation](https://web.mit.edu/kerberos/krb5-latest/doc/plugindev/clpreauth.html)
and the selected release's `clpreauth_plugin.h` for the interface contract.

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

Use synthetic serialization fixtures and negative cases before live tests.
Include independent checks against the KDC-side decoder/verifier so an encoder
and decoder sharing the same mistake cannot falsely establish compatibility.
Keep any reference/oracle tooling outside the shipped dependency graph.

Live acceptance is a TGT obtained with the enrolled security key, stored through
the new MIT build and usable by existing macOS consumers. Record the tested
FreeIPA/Kerberos versions, key model/firmware, UV mode, macOS version and CPU.
Enrollment is initially an external prerequisite; no real credentials or
secret-bearing traces belong in source control.
