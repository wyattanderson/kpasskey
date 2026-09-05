# Application-owned Kerberos configuration

## Contract

KPasskey must not require or silently inherit a system/user `krb5.conf`.
Configuration originates in native application settings, potentially including
managed preferences later, and reaches the worker as a validated, immutable
snapshot for each operation. A plist is a storage format for typed settings,
not an arbitrary Kerberos configuration-language input.

Initial precedence: application defaults, saved user settings, then managed
values for keys explicitly marked as managed. The client applies precedence;
the worker validates effective values. The console harness constructs the same
settings model. Secrets are supplied by interactions, never stored in plists.

## Proposed settings

| Group | Fields and policy |
| --- | --- |
| Identity | Principal and realm; explicit treatment of unqualified names |
| Server discovery | Explicit KDC endpoints or explicitly enabled DNS discovery; validate host/port/transport |
| Realm mapping | Realm-to-RP-domain policy and any necessary host/domain mappings |
| Name handling | Canonicalization, reverse DNS and referral policy, with documented defaults |
| Ticket options | Lifetime, renewable lifetime, forwardability, authentication mode |
| Cache | Worker-supported shared-cache selection and default-switch policy |
| Trust, from M4 | Approved PKINIT CA anchors and expected KDC identity policy |
| Operation policy | Network/device/interaction deadlines and supported retry behavior |

No default lab realm, local checkout path, principal, global armor-cache name,
or unrestricted library/plugin search path belongs in shipped settings.
Cache selection is a constrained policy, not an arbitrary path from the UI.

## MIT integration approach

Use a non-null, application-created profile with `krb5_init_context_profile`
and appropriate context flags, plus per-request initial-credential options.
Passing a null profile would recreate the default-file dependency. A supplied
profile is copied, so backend lifetime/copy semantics matter. The secure-context
flag ignores environment variables covered by that context API; separately
audit caches, plugins, and dependent libraries rather than assuming it sanitizes
the entire process. See [MIT context-profile API](https://web.mit.edu/kerberos/krb5-latest/doc/appdev/refs/api/krb5_init_context_profile.html).

Preferred implementation is an immutable in-memory backend using MIT's public
`profile_init_vtable` facility. Its installed `profile.h` defines lookup/free,
copy/cleanup, and optional iteration callbacks. Implement the actual operations
required by our MIT version and selected modules, including section iteration
where used. Do not assume a lookup-only stub will support plugin discovery.

Milestone 3 must demonstrate that every required setting reaches the correct
library operation, and that missing relations have the intended defaults.
Use explicit cache handles and worker-owned resources. No process-global
environment mutation per request, generated persistent `krb5.conf`, config-file
includes, or shell invocation is part of the design. If a selected upstream
feature proves file-only, document a narrow resource adapter and its lifecycle;
do not silently replace the typed configuration with a generated config file.

Public API details and behavior must be verified against the MIT version
selected in milestone 1. Header availability alone is not behavioral validation.

## Resources and ticket publication

CA certificate bytes may come from a bundled or explicitly imported resource.
If stock PKINIT requires a filename, the worker can materialize an app-owned
certificate resource with controlled lifetime and permissions. That is distinct
from relying on an external Kerberos configuration. Define how imported trust
is approved and updated. Never disable certificate checks to simplify discovery.

Anonymous PKINIT produces FAST armor for the later passkey mode; it is not a
second user credential or a Secure Enclave certificate requirement. Prefer an
operation-owned memory cache if supported by the selected APIs. If a temporary
file is unavoidable, use unique names, restrictive permissions, and cleanup.

Stage newly obtained user credentials privately and publish through the chosen
MIT cache API only after authentication succeeds. Verify that signed-worker
credentials are visible to system consumers; existing prototype evidence is
insufficient for the new build. Resolve MIT/Apple ABI boundaries through the
upstream cache backend, not casts between incompatible structures or custom
messages to Apple's credential daemon.

Tests must include conflicting `KRB5_CONFIG`/cache environment settings, two
successive distinct realm snapshots, publication failure, and coexistence with
an already populated shared cache. Opt-in live tests must document network,
test-account, and cleanup requirements without changing production settings.
