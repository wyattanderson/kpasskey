# KPasskey project plan

Status: milestone 1 implemented and build-tested on arm64 macOS.
Milestones 2 onward remain pending; no authentication is implemented.
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

- [x] Select and pin a mutually compatible stable Bazel, Xcode/SDK, rules_cc,
  rules_apple, rules_swift, and rules_foreign_cc combination; add `.bazelversion`
  and commit the appropriate Bzlmod lockfile.
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
- [x] Add minimal build/link/load probes, including a C consumer and a small
  Objective-C or Swift bridge consumer. These are build tests only: no worker,
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

### Implementation evidence — 2026-09-05

- Bazel **8.8.0**, Apple CLT **26.6.0.0.1781586589**, macOS SDK **26.5**,
  Apple clang **21.0.0 (clang-2100.1.1.101)**; arm64 only, minimum macOS **14.0**.
  This is a pinned CLT/SDK build baseline, not a claim that full Xcode,
  Swift compilation, or app/XPC bundles have been tested. Full Xcode is M2 work.
- Rules: apple_support **2.8.1**, rules_cc **0.2.22**, rules_apple **4.5.3**,
  rules_swift **3.6.1**, rules_shell **0.8.0**, platforms **1.1.0**.
  rules_foreign_cc is the checksummed HEAD snapshot
  **f68b351c4691e747f889dc5e4c2cac3cd3b66ea2**, not its latest release.
  `.bazelversion`, `MODULE.bazel`, and `MODULE.bazel.lock` record the pins.
- Sources: MIT krb5 **1.22.2**, libfido2 **1.17.0**, libcbor **0.14.0**,
  zlib **1.3.2**, OpenSSL **3.6.4**. Build tools: CMake **4.4.3**,
  Ninja **1.13.2**, GNU Make **4.4.1**. Checksums and license metadata are in
  `MODULE.bazel` and `third_party/README.md`.
- OpenSSL **4.0.2** was attempted. Its opaque ASN.1 structures and changed
  const-qualified APIs break stock MIT PKINIT. **3.6.4**, the newest maintained
  3.x release, builds stock PKINIT without a crypto port or suppressed errors.
- `bazel test //...` passes the C consumer, Objective-C bridge, PKINIT load,
  linkage audit, and relocation probe. `//:milestone1` groups the five tests.
  The relocation test uses a path containing spaces and an empty environment.
- `BAZEL=/absolute/path/to/bazel-8.8.0-darwin-arm64 ./build/reproduce.sh`
  creates a fresh output base, fetches inputs, and then runs all five tests
  with `--nofetch --lockfile_mode=error`. Build actions run in the Darwin
  sandbox with network disabled and a system-only PATH. No Homebrew libraries
  or tools are required. The final clean run completed **71 actions** and
  **5/5 passing tests** on 2026-09-05. See `docs/BUILD.md` for prerequisites
  and commands.
- The linkage audit confirms arm64/macOS 14.0 artifacts, versioned `@rpath`
  library references, valid ad-hoc signatures, CCAPI framework linkage, and
  stock PKINIT entry points. Cache publication, KDC access, FIDO device access,
  and execution on the oldest deployment OS are intentionally not claimed.
- MIT's legacy Kerberos framework and private `com.apple.GSSCred` protocol
  dependencies are documented. Working linkage is not public Apple API support.

## Milestone 2 — XPC boundary and console harness

**Purpose:** prove that the future UI can drive an out-of-process worker.

Deliverables:

- [ ] Finalize the contract in docs/ARCHITECTURE.md: version negotiation,
  operation IDs, configuration snapshot, interaction IDs, events, results,
  error categories, cancellation, and connection lifecycle.
- [ ] Implement shared Objective-C-compatible XPC protocols and explicitly
  allowed secure message types. Keep the client adapter usable from Swift.
- [ ] Build an embedded `.xpc` service with rules_apple. Start with a scripted
  fake worker that emits interaction requests and terminal results.
- [ ] Package a minimal console harness in a host `.app` so it exercises the
  same embedded-service discovery as the eventual UI. Its executable is
  invoked from the terminal; no graphical UI is needed.
- [ ] Define and test the development and release peer-authorization policy.
  Use verified process/signing identity, not a bundle ID supplied in a message.
- [ ] Make the harness display events and submit interaction responses using
  exactly the same client interface the UI will use.

Acceptance:

- [ ] Worker executes in a distinct process without root, a persistent global
  Mach service, or manually installed launchd configuration.
- [ ] Round trips, repeated operations, rejected concurrent requests, malformed
  messages, stale interaction responses, cancellation, worker termination,
  disconnect, and reconnection have defined and tested outcomes.
- [ ] Cancellation is acknowledged promptly and eventually terminates the
  operation within a documented bound; exactly one terminal result is observed.
- [ ] Moving the host bundle does not break worker discovery.
- [ ] No Kerberos calls or device access yet. This milestone validates the
  process boundary, not authentication.

## Milestone 3 — Plain Kerberos worker and configuration

**Purpose:** obtain an ordinary password-based TGT through the worker, with no
KPasskey passkey plugin loaded or used.

Deliverables:

- [ ] Implement the typed, versioned configuration model in docs/CONFIGURATION.md.
- [ ] Translate settings into a non-default in-memory MIT profile and explicit
  credential options. Prove all required profile lookup, copy, and iteration
  behavior for the selected MIT version.
- [ ] Create a context for each operation, isolate configuration/environment
  behavior, and establish a policy for DNS discovery and canonicalization.
- [ ] Implement password interactions through XPC using the same harness.
  Also define how unexpected additional prompts are rejected or represented.
- [ ] Acquire credentials into a private staging cache, then publish successfully
  acquired credentials to the selected shared macOS cache through library APIs.
- [ ] Implement metadata reporting and explicit, scoped cache selection.
  Do not overwrite or destroy unrelated credentials on failure.
- [ ] Define timeout, cancellation, error mapping, and cleanup for blocking
  Kerberos calls. Audit every cache/backend environment dependency separately.

Acceptance:

- [ ] A configured harness obtains a password-based TGT visible to the selected
  system `klist` and at least one real system Kerberos consumer.
- [ ] No external `krb5.conf`, shell variables, or modifications to `/etc` are
  required. An intentionally conflicting environment/configuration cannot
  silently change the chosen realm, KDC policy, or cache destination.
- [ ] Wrong password, unavailable KDC, invalid realm, cancellation, expired
  interaction, and sequential operations with different settings are tested.
- [ ] Credentials are not reported as available until publication succeeds;
  authentication success and cache-publication failure remain distinguishable.
- [ ] Passwords are absent from command lines, configuration plists, normal
  logging, crash annotations, and test output. The harness reads them securely.
- [ ] The worker works after bundle relocation and still uses the bundled MIT
  implementation, not Apple's different Kerberos ABI by accident.

## Milestone 4 — Purpose-built passkey plugin

**Purpose:** obtain a passkey TGT against the existing FreeIPA server protocol.

Deliverables:

- [ ] Define protocol fixtures and expected rejection behavior from the KDC-side
  implementation; use synthetic data and an independent decoding oracle.
- [ ] Implement the minimal MIT clpreauth plugin described in docs/PROTOCOL.md.
  Reuse no old helper CLI, terminal prompt parsing, or checkout-relative paths.
- [ ] Add the libfido2 adapter with device selection, PIN/UV policy, explicit
  operation deadlines, cancellation, and useful device error categories.
- [ ] Route assertions through MIT's responder boundary into the worker's XPC
  interactions. The plugin itself owns no windows or XPC listener.
- [ ] Add anonymous PKINIT FAST armor acquisition, explicit CA trust, ephemeral
  armor-cache ownership, and failure behavior. This introduces stock PKINIT
  execution after plain Kerberos was validated independently.
- [ ] Load only the bundled passkey plugin using application-owned configuration
  and paths, and require FAST for the passkey operation.
- [ ] Make passkey-only requests fail closed instead of silently obtaining a
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
- [ ] Parser tests cover invalid phase, malformed/oversized data, bad Base64,
  wrong hash length, bad framing, and realm/RP mismatch.
- [ ] Valid and malformed authenticator-data encodings are tested against the
  actual server expectations. Cancellation/failure never publishes new tickets.
- [ ] End-to-end success is demonstrated without building or shipping SSSD.

## Later — Native application and release

After the first four milestones, add the SwiftUI/AppKit menu-bar application,
global shortcut, authentication window, settings UI, optional login item, and
ticket status. Keep interaction decisions in a shared client adapter so the
harness remains a useful diagnostic tool.

Release acceptance includes a clean Mac with no Homebrew, bundle relocation
(including paths containing spaces), hardware tests, nested code-signing,
Hardened Runtime, notarization, stapling, and Gatekeeper assessment. Publish a
signed archive or DMG, checksums, third-party notices, and supported macOS/CPU
versions on GitHub Releases. Test every architecture actually advertised.

## Open decisions and ownership

| Decision | Resolve by | Default direction |
| --- | --- | --- |
| Bazel/rules/Apple SDK and minimum macOS | M1 resolved | Pins above; CLT baseline tested; full Xcode/bundles validated in M2 |
| Intel support | M1 resolved | arm64 only; x86_64 is not a release requirement |
| MIT/libfido2 crypto dependencies | M1 resolved | Bundle OpenSSL 3.6.4; stock PKINIT is incompatible with 4.0.2 |
| Static versus dynamic third-party linkage | M1 resolved | Shared MIT/OpenSSL; static libfido2/libcbor/zlib; one MIT runtime |
| JSON library | M4 | Deferred until the passkey wire parser is needed; use an established parser |
| Shared-cache backend support and visibility | M1/M3 | Revalidate existing MIT-to-macOS path |
| XPC DTOs, service identity, console hosting | M2 | Embedded unprivileged NSXPC service |
| Profile backend completeness and discovery | M3 | Immutable in-memory profile plus explicit options |
| FreeIPA version test matrix | M4 | Start with the working deployment, record exact versions |
| New-code license and dependency provenance | Before distribution | Track origin from first commit; no automatic relicensing of copied code |

Update this plan with actual commands, pinned versions, evidence, and remaining
failures as each milestone lands. A successful stub or compile is not evidence
that an authentication or release milestone is complete.
