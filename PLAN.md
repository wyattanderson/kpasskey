# KPasskey project plan

Status: milestones 1–3 implemented on arm64 macOS, including live password
authentication and use of the published TGT by Apple's system Kerberos tools.
Milestone 4 implementation is present with offline protocol, plugin and XPC
coverage; live passkey authentication and hardware acceptance remain pending.
Decisions recorded: 2026-09-05.

## Objective and scope

Build a self-contained macOS application that obtains a FreeIPA TGT using a
USB FIDO2 security key and publishes it into the user's shared macOS Kerberos
credential cache. A global shortcut should show a native window with useful
device selection, PIN, touch, cancellation, and error handling.

Deliver a relocatable, signed, notarized application on GitHub Releases.
Neither installation nor authentication should depend on Homebrew, shell
startup files, environment variables, or user-written Kerberos configuration.

The first four milestones deliberately establish the build, process boundary,
and ordinary Kerberos behavior before introducing passkey authentication.
Do not combine them into one app implementation effort.

## Mandatory implementation policy

Swift is the primary and mandatory language for all project-owned executable
code across every milestone, including XPC contracts, worker/harness code,
Kerberos and FIDO adapters, plugin logic, tools, and tests. Use modern Swift
tooling and Swift Testing for automated tests. A different test framework
requires a documented functional capability unavailable in Swift Testing.

C or Objective-C is allowed only when **absolutely and functionally necessary**
because supported Swift interoperability cannot express a required API or ABI.
Document the specific limitation, keep the shim minimal, and keep the remaining
logic in Swift. C dependencies, C ABI entry points, and Objective-C-compatible
protocols do not automatically qualify. Build-wiring effort and existing C
examples do not qualify either. Required upstream libraries keep their upstream
languages; Bazel remains the build system. [AGENTS.md](AGENTS.md) defines the
repository-wide policy.

## Existing evidence and its limits

The sibling `macos-passkey` prototype has a working path consisting of Homebrew
MIT krb5, an SSSD client plugin, and a reduced libfido2 assertion helper. Its
launcher first obtains anonymous PKINIT FAST armor and then authenticates with
the passkey. Existing work reports successful storage in the shared macOS
cache and use by system consumers.

That establishes a useful reference, not proof that our independent Bazel
build, signed worker, deployment targets, or device handling will work. Repeat
the relevant tests with KPasskey artifacts. Never import the existing fixed
armor-cache path, trace defaults, local CA path, principal, or realm as product
defaults. Do not copy the lab's passkey logs into test fixtures.

The prototype compiles approximately 1,302 lines of SSSD C implementation
(comments included): 400 for the client plugin, 648 for message utilities, and
254 for common utilities. Its separate assertion helper is already a reduced
386-line local implementation. No SSSD daemon is necessary for the new client.

## Milestone 1 — Bazel and dependency builds

**Purpose:** resolve build-system problems before implementing authentication.

Deliverables:

- [x] Configure compatible Bazel and Apple build rules with Xcode discovery;
  record required dependency pins in the build configuration and commit the
  appropriate Bzlmod lockfile.
- [x] Set an explicit minimum macOS version and initial architecture. Start
  with arm64; decide and document whether x86_64 is a release requirement.
- [x] Fetch MIT krb5, libfido2, libcbor, and required crypto/build dependencies
  as pinned external repositories with checksums and license metadata.
- [x] Build dependencies from source under Bazel. Initially prefer upstream
  configure/Make and CMake builds through rules_foreign_cc, behind local labels.
- [x] Build MIT's client libraries, the profile API, the macOS shared-cache
  backend, and stock PKINIT support needed for the later FAST milestone.
- [x] Build libfido2 with the macOS HID backend and an explicitly selected
  feature set. Resolve libcbor, libcrypto, and zlib without host package lookup.
- [x] Add minimal Swift build/link/load probes and Swift Testing cases with
  signed command-line consumers. These are build tests only: no worker,
  passkey implementation, UI, or live authentication.
- [x] Record the native-library versus bundled-library choices, configure
  options, generated tools, and any narrowly scoped patches in docs/BUILD.md.

Acceptance:

- [x] Clean Bazel output base can fetch and build the declared dependencies
  using the documented prerequisites, with no Homebrew requirement.
- [x] Once fetched, build actions do not fetch further sources or discover
  undeclared libraries through pkg-config, PATH, `/opt/homebrew`, or `/usr/local`.
- [x] Architecture and deployment target are consistent across native and
  foreign builds. Host tools are distinguished from target artifacts.
- [x] Link/load probes pass. PKINIT and cache-backend artifacts exist and their
  linkage is audited; actual authentication is intentionally deferred.
- [x] Any SDK/framework dependency with questionable public-API status is
  documented, especially the macOS cache integration. Do not describe a
  working legacy path as automatically supported by Apple.
- [x] A reproducible CI build or documented clean-machine reproduction exists.

### Implementation evidence

- Bazel selects full Xcode for both native and foreign builds and discovers
  its version and default SDK. Shared Swift probe libraries build through
  rules_swift and link into rules_apple command-line applications. App/XPC
  bundles remain M2 work. Required pins and compatibility rationale live in
  the build files.
- `bazel test //...` passes the Swift consumer, Swift bridge, PKINIT load,
  linkage audit, and relocation probe. `//:milestone1` groups these checks.
  The relocation test uses a path containing spaces and an empty environment.
- Direct Bazel commands in `docs/BUILD.md` reproduce the build in a fresh
  output base with a locked fetch followed by tests without fetching.
  Compilation/tests run in the Darwin sandbox with network disabled and a
  system-only PATH; rules_apple binary signing uses its required local
  strategy. No Homebrew libraries or tools are required.
- Linkage and relocation checks cover the configured architecture and
  deployment target, relative library references, signatures, CCAPI linkage,
  and stock PKINIT entry points. Both Apple executables run after relocation
  without modification after signing. Cache publication, KDC access, FIDO device
  access, and execution on the oldest deployment OS remain unverified.
- MIT's legacy Kerberos framework and private `com.apple.GSSCred` protocol
  dependencies are documented. Working linkage is not public Apple API support.

### Swift probe migration

The initial C/Objective-C probes and shell test drivers have been replaced by
Swift. Declaration-only umbrella headers expose the upstream C libraries;
no C or Objective-C implementation shim is needed.

- [x] Replace the Objective-C bridge and C entry point with a Swift consumer
  that calls the MIT profile/context APIs directly. Preserve the rules_apple
  command-line application and its signed, unmodified relocation check.
- [x] Replace the C dependency probe with Swift. Expose the declared
  third-party headers as Clang modules through Bazel, retain explicit pointer
  ownership/cleanup, and preserve the bundled-library origin, dependency,
  PKINIT symbol, and shared MIT runtime checks.
- [x] Express test cases in Swift Testing through rules_swift. Keep a small
  Swift executable for empty-environment relocation so a test runner does not
  become a requirement of the relocated probe. Reuse probe logic where useful.
- [x] Replace shell test orchestration with Swift Testing and Foundation
  process/file APIs. Invoke macOS inspection tools directly, without a shell.
- [x] Run `bazel test //...` and the documented clean reproduction after the
  migration. Preserve linkage, deployment-target, signing, PKINIT loading, and
  relocation coverage; validate Swift runtime availability after relocation.

## Milestone 2 — XPC boundary and console harness

**Purpose:** prove that the future UI can drive an out-of-process worker.

Deliverables:

- [x] Finalize the contract in docs/ARCHITECTURE.md: version negotiation,
  operation IDs, configuration snapshot, interaction IDs, events, results,
  error categories, cancellation, and connection lifecycle.
- [x] Implement shared XPC protocols and explicitly allowed secure message
  types in Swift using Objective-C interoperability. Implement the shared
  client adapter in Swift.
- [x] Build an embedded `.xpc` service with rules_apple. Start with a scripted
  fake worker that emits interaction requests and terminal results.
- [x] Package a minimal console harness in a host `.app` so it exercises the
  same embedded-service discovery as the eventual UI. Its executable is
  invoked from the terminal; no graphical UI is needed.
- [x] Define and test the development and release peer-authorization policy.
  Use verified process/signing identity, not a bundle ID supplied in a message.
- [x] Make the harness display events and submit interaction responses using
  exactly the same client interface the UI will use.

Acceptance:

- [x] Worker executes in a distinct process without root, a persistent global
  Mach service, or manually installed launchd configuration.
- [x] Round trips, repeated operations, rejected concurrent requests, malformed
  messages, stale interaction responses, cancellation, worker termination,
  disconnect, and reconnection have defined and tested outcomes.
- [x] Cancellation is acknowledged promptly and eventually terminates the
  operation within a documented bound; exactly one terminal result is observed.
- [x] Moving the host bundle does not break worker discovery.
- [x] No Kerberos calls or device access yet. This milestone validates the
  process boundary, not authentication.

### Implementation evidence

- `xpc/` contains the Swift secure-coding contract, main-actor client adapter,
  fake session, service entry point, and console entry point. rules_apple embeds
  and signs the worker inside the host app. No C/Objective-C implementation,
  shell launcher, installed launchd configuration, or new dependency is needed.
- Swift Testing covers secure archives, message validation, negotiation,
  operation/interaction replay, deadline cleanup, and both cancellation versus
  completion orderings. The real host exercises success/failure, sequential and
  rejected concurrent starts, cancellation, stale responses, malformed requests
  and oversized archives, disconnect, forced worker termination, and recovery.
  Terminal results are checked for uniqueness and event sequences for continuity.
- The integration test invokes the signed host executable directly, verifies a
  distinct worker process under the user identity, moves the app to a path with
  spaces, checks nested signatures, and reruns with an empty environment. EOF
  at a console prompt cancels. Host and worker link only platform libraries;
  there are no Kerberos calls or device accesses.
- Development mode requires an explicit build flag and pins live peers to the
  expected bundled code hash and identifier. A differently signed executable
  claiming the host identifier is rejected. Default/release policy requires an
  Apple-anchored peer from the same signing team and fails closed for ad-hoc code.
  Positive Developer ID signing and oldest-OS execution remain release checks;
  development tests do not establish distribution readiness.
- `bazel test --config=development //...` exercises the live XPC boundary and
  milestone 1 regression checks. `bazel test //...` also checks the default
  release policy's refusal of ad-hoc peers. Tests remain in the Darwin sandbox;
  only rules_apple signing actions use its required local execution strategy.
- Cancellation has a one-second client completion bound; a lost/nonresponsive
  worker produces one local failure outcome. Negotiation allows launchd's
  crash-restart delay. Exact lifecycle, deadline, and trust policies are in
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); real blocking authentication
  behavior remains M3/M4 work.

## Milestone 3 — Plain Kerberos worker and configuration

**Purpose:** obtain an ordinary password-based TGT through the worker, with no
KPasskey passkey plugin loaded or used.

Deliverables:

- [x] Implement the typed, versioned configuration model in docs/CONFIGURATION.md.
- [x] Translate settings into a non-default in-memory MIT profile and explicit
  credential options. Prove all required profile lookup, copy, and iteration
  behavior for the selected MIT version.
- [x] Create a context for each operation, isolate configuration/environment
  behavior, and establish a policy for DNS discovery and canonicalization.
- [x] Implement password interactions through XPC using the same harness.
  Also define how unexpected additional prompts are rejected or represented.
- [x] Acquire credentials into a private staging cache, then publish successfully
  acquired credentials to the selected shared macOS cache through library APIs.
- [x] Implement metadata reporting and explicit, scoped cache selection.
  Do not overwrite or destroy unrelated credentials on failure.
- [x] Define timeout, cancellation, error mapping, and cleanup for blocking
  Kerberos calls. Audit every cache/backend environment dependency separately.

Acceptance:

- [x] A configured harness obtains a password-based TGT visible to the selected
  system `klist` and at least one real system Kerberos consumer.
- [x] No external `krb5.conf`, shell variables, or modifications to `/etc` are
  required. An intentionally conflicting environment/configuration cannot
  silently change the chosen realm, KDC policy, or cache destination.
- [x] Wrong password, unavailable KDC, invalid realm, cancellation, expired
  interaction, and sequential operations with different settings are tested.
- [x] Credentials are not reported as available until publication succeeds;
  authentication success and cache-publication failure remain distinguishable.
- [x] Passwords are absent from command lines, configuration plists, normal
  logging, crash annotations, and test output. The harness reads them securely.
- [x] The worker works after bundle relocation and still uses the bundled MIT
  implementation, not Apple's different Kerberos ABI by accident.

### Implementation evidence and validation limits

- `xpc/Configuration.swift` defines effective settings and partial plist loading.
  DNS discovery is on by default; explicit endpoints disable DNS KDC discovery.
  Forwardability defaults on and is configurable, as are ticket lifetimes,
  canonicalization, transport preference, default-cache switching and deadlines.
- MIT's existing native memory-only profile provides lookup, copy and iteration;
  a custom vtable is unnecessary. Swift tests exercise copied-profile lifetime,
  repeated relations, missing keys, section iteration and explicit credential
  options with conflicting configuration/cache/trace environment settings.
  An opt-in, password-free test also resolved the live realm through MIT's DNS
  TXT lookup for an unqualified username and supplied discovery domain.
- Protocol version 2 retains scripted boundary tests and adds a separate bounded
  password field and validated success metadata. Native work is off the main
  actor. Cancellation gates publication; a blocked unpublished operation causes
  worker exit after its cleanup grace. Native cache-commit reply loss remains
  an indeterminate outcome, documented in CONFIGURATION.md.
- A private MEMORY cache stages credentials. Successful publication creates a
  distinct API cache; rollback owns only that new cache. Tests exercise rollback
  and survival of an unrelated memory cache without modifying a user's cache
  collection. The client rejects password success without publication metadata.
- Live password authentication used DNS KDC discovery, produced a forwardable
  TGT, and survived host/worker exit. Apple's `/usr/bin/klist` displayed it and
  `/usr/bin/kgetcred` used it to obtain a host service ticket. The worker must
  set `JoinExistingSession`: the initial isolated XPC audit session hid its
  caches from the user's terminal. This setting has a bundle regression check.
- A pseudo-terminal regression covers hidden input, backspace, timeout and
  terminal restoration. Password-rejection testing uses a synthetic local KDC
  returning PREAUTH_FAILED, avoiding real-account lockout attempts. Other tests
  cover unavailable endpoints, invalid settings/realms, stale/expired responses,
  cancellation, and sequential realm snapshots through relocated XPC bundles.
- Full development and default-policy Bazel suites retain dependency, linkage,
  relocation and peer-signature checks. The system HTTPS consumer attempt stopped
  at the lab CA trust chain; TLS verification was not disabled. Live testing of
  nonforwardable tickets and forced native API-cache failure remains additional
  deployment coverage; the option and rollback paths have automated coverage.
  Oldest-OS and Developer ID distribution checks remain release work.

## Milestone 4 — Purpose-built passkey plugin

**Purpose:** obtain a passkey TGT against the existing FreeIPA server protocol.

Deliverables:

- [x] Define protocol fixtures and expected rejection behavior from the KDC-side
  implementation; use synthetic data and an independent decoding oracle.
- [x] Implement the minimal MIT clpreauth plugin described in docs/PROTOCOL.md
  in Swift, with a C ABI shim only if a documented interoperability limitation
  makes it absolutely and functionally necessary. Reuse no old helper CLI,
  terminal prompt parsing, or checkout-relative paths.
- [x] Add the libfido2 adapter with device selection, PIN/UV policy, explicit
  operation deadlines, cancellation, and useful device error categories.
- [x] Route assertions through MIT's responder boundary into the worker's XPC
  interactions. The plugin itself owns no windows or XPC listener.
- [x] Add anonymous PKINIT FAST armor acquisition, explicit CA trust, ephemeral
  armor-cache ownership, and failure behavior. This introduces stock PKINIT
  execution after plain Kerberos was validated independently.
- [x] Load only the bundled passkey plugin using application-owned configuration
  and paths, and require FAST for the passkey operation.
- [x] Make passkey-only requests fail closed instead of silently obtaining a
  password-based ticket. Plain-password authentication remains a separate mode.

Acceptance:

- [ ] Passkey assertion leads to a TGT and usable shared-cache credentials via
  the same harness/worker boundary established in milestones 2 and 3.
- [ ] Validate against the intended FreeIPA version(s), including required UV,
  allowed-credential selection, exact challenge/state handling, and no armor.
- [ ] Exercise key absence, wrong key, several keys, removal during interaction,
  wrong PIN, exhausted/blocked PIN state where safely testable, device UV,
  timeout, cancellation, and worker restart. Simulate lockout errors rather
  than deliberately exhausting a user's real key.
- [x] Parser tests cover invalid phase, malformed/oversized data, bad Base64,
  wrong hash length, bad framing, and realm/RP mismatch.
- [x] Valid and malformed authenticator-data encodings are tested against the
  actual server expectations. Cancellation/failure never publishes new tickets.
- [ ] End-to-end success is demonstrated without building or shipping SSSD.

### Implementation evidence and remaining acceptance

- `passkey/` implements framing, bounded Codable messages and the MIT clpreauth
  vtable entirely in Swift. The C entry point and callbacks require no shim.
  It validates FAST availability, callback version, exact realm/RP binding,
  allow-list membership, original state/challenge, CBOR authdata and UP/UV before
  setting the armor reply key and disabling fallback. It owns no device handle,
  prompt, helper process or XPC listener.
- Synthetic fixtures use Foundation's object decoder independently of the
  production Codable decoder, reproduce the KDC cookie checks, and exercise the
  actual libfido2 authdata decoder and signature verifier with generated P-256
  proofs. Negative tests include malformed framing, phases, Base64, lengths,
  CBOR/trailing bytes, raw-versus-wrapped authdata, UV and realm/RP mismatch.
  Callback tests exercise a complete responder answer with a null prompter,
  state mismatch, missing armor and unsupported interface versions.
- `xpc/FIDO.swift` selects from an operation-scoped HID manifest, uses onboard
  UV or one requested PIN attempt, preserves device failure categories and
  applies the remaining deadline to native device calls. XPC version 3 routes
  device choices/PINs and verifies the requested success mode. Terminal input
  is hidden and restored on cancellation. Blocked native calls retain the
  existing worker-exit bound; cancellation gates publication.
- `xpc/Passkey.swift` creates separate PKINIT and passkey contexts, supplies an
  explicit CA, owns a MEMORY armor cache, requires FAST and checks MIT's selected
  preauthentication type before reusing the existing cache publication path.
  No SSSD or old assertion helper is in the build or runtime graph.
- The signed host contains only the selected PKINIT artifact and the Swift
  plugin in `Contents/PlugIns`. Relocation checks load both and verify their
  shared MIT runtime. Tests cover invalid trust through XPC, mode isolation,
  cancellation/deadlines, safe simulated PIN/block/removal error categories and
  existing password/publication/peer-identity behavior. `//:milestone4` groups
  the relevant checks. Full development and default-policy Bazel suites pass.
- A user-run lab attempt completed anonymous PKINIT armor acquisition, then
  failed passkey preauthentication before device interaction. A synthetic
  regression reproduced the failure through MIT's actual loader: the plugin
  rejected its reported minor interface version. Matching the bundled MIT
  plugins' compatibility check fixes loading; the regression now reaches the
  plugin's armor guard. Live passkey authentication still needs a rerun. No passkey TGT or
  system-consumer use is claimed. Complete the live FreeIPA/version and key/firmware/UV matrix,
  multiple/absent/wrong/removed-key tests, cancellation/restart during device work,
  and system `klist`/consumer checks before marking milestone 4 accepted. Simulate
  lockout errors; do not exhaust a user's real PIN retry counter.

## Native application and release

The next development phase is tracked in [NATIVE_PLAN.md](NATIVE_PLAN.md).
That plan owns the native experience and distribution acceptance; this document
retains the authentication milestones and their recorded validation limits.

## Open decisions and ownership

| Decision | Resolve by | Default direction |
| --- | --- | --- |
| Bazel/rules/Apple SDK and minimum macOS | M1 resolved | Build configuration owns pins and deployment target; discover Xcode/SDK; app/XPC bundles validated in M2 |
| Intel support | M1 resolved | arm64 only; x86_64 is not a release requirement |
| MIT/libfido2 crypto dependencies | M1 resolved | Bundle OpenSSL; compatibility rationale lives beside its pin in MODULE.bazel |
| Static versus dynamic third-party linkage | M1 resolved | Shared MIT/OpenSSL; static libfido2/libcbor/zlib; one MIT runtime |
| JSON library | M4 resolved | Foundation Codable in production; independent JSONSerialization fixture decoding |
| Shared-cache backend support and visibility | M3 resolved | Unique API cache in the caller's audit session; live Apple klist/kgetcred validated |
| XPC DTOs, service identity, console hosting | M2 resolved | Secure Swift envelopes; verified peer signing; embedded unprivileged service and console host |
| Profile backend completeness and discovery | M3 resolved | Native memory-only MIT profile, explicit options, DNS realm/KDC discovery |
| FreeIPA version test matrix | M4 | Start with the working deployment, record exact versions |
| New-code license and dependency provenance | Before distribution | Track origin from first commit; no automatic relicensing of copied code |

Update this plan with meaningful validation and remaining failures as each
milestone lands. Keep pins in the build configuration. A successful stub or
compile is not evidence that an authentication or release milestone is complete.
