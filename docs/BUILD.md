# Bazel dependency builds

Milestone 1 builds dependencies and exercises Swift interoperability with C
libraries, dynamic loading, linkage, and relocation through Swift Testing.
Milestone 2 adds a signed console host and embedded scripted XPC worker.
Milestone 3 adds ordinary password authentication and shared-cache publication;
live acceptance is tracked in PLAN.md. Milestone 4 adds the Swift passkey plugin,
FIDO adapter and FAST armor. The native app in `app/` adds SwiftUI sign-in,
settings and menu-bar scenes; [NATIVE_PLAN.md](../NATIVE_PLAN.md) tracks that work.

Following [AGENTS.md](../AGENTS.md), Swift and modern Swift tooling are required
for project-owned implementation and executable tools, with Swift Testing required
for automated tests unless a needed capability is unavailable and documented.
C/Objective-C is allowed only when absolutely and functionally necessary for
an API/ABI that supported Swift interoperability cannot express. Upstream
native dependencies retain their implementation languages, and Bazel Starlark
and declarative configuration remain the build mechanism.

## Setup

Only arm64 macOS is supported. The platform and minimum deployment target
are defined in the Bazel configuration; x86_64 and universal releases are not
requirements. `.bazelversion`, `MODULE.bazel`, and `MODULE.bazel.lock` record
the build-tool and dependency versions.

Install Xcode and complete its first-launch setup, including license
acceptance. `.bazelrc` selects `/Applications/Xcode.app` with the repository
`DEVELOPER_DIR` setting so native and foreign builds use the same
installation even when the machine-wide `xcode-select` setting points to
Command Line Tools. Bazel discovers Xcode's version and default SDK; neither
is pinned. If Xcode lives elsewhere, override `--repo_env=DEVELOPER_DIR=...`.
Let Bazel derive action/test `DEVELOPER_DIR` and `SDKROOT` from that discovered
Xcode. An explicit action `DEVELOPER_DIR` bypasses part of Bazel's SDK discovery
and can leave the Swift test runner looking for frameworks in Command Line
Tools instead. Do not work around this with a pinned SDK path or shell launcher.

The probes use `rules_swift` for compilation and Swift Testing, and `rules_apple`
to link and ad-hoc sign standalone command-line applications. The Swift language
mode is enabled in `.bazelrc`; use the selected Xcode's Swift Testing library
and the test runner supplied by rules_swift. No separate package manager or
project-owned test launcher is needed. M2 also uses the native application and
XPC service bundle rules. Execution on the oldest supported macOS remains
release validation.
The Apple SDK/compiler and macOS utilities are documented host inputs, not a
claim of a completely hermetic or SDK-independent toolchain.

## Reproduce

Use Bazelisk to honor `.bazelversion`, or install the corresponding official
Bazel binary on PATH. Homebrew is not needed.

From the repository root:

```sh
bazel test //...
```

For a new output base with no previously compiled artifacts:

```sh
kpasskey_output_base=$(mktemp -d "${TMPDIR:-/tmp}/kpasskey-xcode.XXXXXX")
bazel --nosystem_rc --nohome_rc --output_base="$kpasskey_output_base" fetch --lockfile_mode=error //...
bazel --nosystem_rc --nohome_rc --output_base="$kpasskey_output_base" test --nofetch --lockfile_mode=error //...
```

These direct Bazel commands ignore user/system bazelrc files, use a fresh output base,
fetch `//...` with the committed lockfile, then test `//...` with `--nofetch`
and `--lockfile_mode=error`. Repository downloads occur during fetch only.
Compilation and test actions use the Darwin sandbox with network access
disabled. rules_apple marks `SignBinary` and `ProcessAndSign` actions
`no-sandbox`, so those signing mnemonics use the local strategy. A shared
Bazel repository download cache may satisfy checksummed fetches; there is no
shared action cache in the fresh output base. The output base and logs remain
available for inspection. No prerequisite or reproduction wrapper is required.

When deliberately updating pins, run `bazel mod deps --lockfile_mode=update`,
then `bazel test //...`, review the lockfile, and rerun the clean reproduction.
Do not turn the HEAD override into a moving branch reference: resolve a new
commit and checksum explicitly.

## XPC console harness

The default build compiles the release peer policy, which refuses ad-hoc peers.
Use the explicit development configuration to exercise locally signed bundles:

```sh
bazel test --config=development //...
bazel build --config=development //xpc:harness
```

`//:milestone2` selects just the secure-coding/state-machine and embedded-XPC
integration tests. Without `--config=development`, its integration test verifies
that the default policy refuses the ad-hoc host. With development enabled it
launches the actual console executable, exchanges messages with launchd's
embedded worker, moves the signed host to a path containing spaces, and repeats
the lifecycle checks in an empty environment. Both modes must pass. Tests use
Swift Testing and remain in the Darwin sandbox; XPC integration is local to this
Mac's per-user launchd and is excluded from remote execution.

The harness archive contains `KPasskeyHarness.app`, with `Worker.xpc` in
`Contents/XPCServices`. Extract the Bazel archive with macOS `ditto` and run
the console executable directly:

```sh
ditto -x -k bazel-bin/xpc/harness.zip /tmp/kpasskey-console
/tmp/kpasskey-console/KPasskeyHarness.app/Contents/MacOS/KPasskeyHarness
```

The fake prompts accept `key-1`, then `continue`, or `cancel`. `--automatic`
answers those synthetic prompts; `--exercise` runs failure/lifecycle scenarios,
including password requests to unavailable synthetic KDCs, and intentionally
kills only the negotiated worker. Real password mode is selected explicitly:

```sh
/tmp/kpasskey-console/KPasskeyHarness.app/Contents/MacOS/KPasskeyHarness --password user@REALM
/tmp/kpasskey-console/KPasskeyHarness.app/Contents/MacOS/KPasskeyHarness --settings settings.plist
```

The password is read securely from the terminal, never arguments or a file.
Settings support DNS realm/KDC discovery and default to forwardable tickets;
see [CONFIGURATION.md](CONFIGURATION.md). Shared caches are touched only after
successful real authentication. `//:milestone3` includes profile/options,
publication rollback, secure-terminal and XPC tests. Password mode does not
access devices; no launch agent or privileged installation is involved.
The host's native CcInfo bundling
support places the declared MIT/OpenSSL dylibs in `Contents/Frameworks`; the
worker's standard rules_apple rpath finds them there. `xpc/Host.plist`
and `xpc/Worker.plist` provide the required bundle package types and application
service/run-loop declarations; rules_apple supplies the executable/identifier
and nesting. No post-build patching or re-signing is needed for relocation.

The development signing policy and its local-bundle trust assumption are in
[ARCHITECTURE.md](ARCHITECTURE.md#peer-authorization). Release builds must omit
the development flag and sign both endpoints with the release identity. Positive
Developer ID acceptance and distribution validation remain later release work.
The console harness is a development tool, not the finished native application.

## Passkey artifacts and harness

`//passkey:kpasskey` links the Swift C entry point as a signed macOS dylib.
rules_apple embeds it beside stock PKINIT in `Contents/PlugIns`; both use the
host's declared MIT/OpenSSL runtime. A small Swift build action extracts only
`pkinit.so` from rules_foreign_cc's installation tree, which cannot be selected
as an individual source label. No shell wrapper, SSSD build or checkout-relative
runtime path is used. Existing library pins remain authoritative in MODULE.bazel.

Run `bazel test --config=development //:milestone4` for protocol, native callback,
FIDO error-policy, configuration, cancellation, console and relocated-XPC checks.
Run both full suites for dependency and release-policy regression coverage.
After extracting the development harness, real passkey mode is:

```sh
KPasskeyHarness.app/Contents/MacOS/KPasskeyHarness --passkey user@REALM --ca /path/to/ca.pem
```

Supply an enrolled USB FIDO2 key and the CA that issued the realm's KDC
certificate. Device selection and PINs are entered at the terminal; the PIN is
never an argument. Settings plists can select the same mode with explicit KDCs,
timeouts and ticket options. See CONFIGURATION.md for trust and failure policy.
Live authentication creates a new shared API cache only after verification;
clean up only that returned cache when testing. Live acceptance remains tracked
separately from successful builds in PLAN.md.

## Dependency closure and local labels

See [third_party/README.md](../third_party/README.md) for source provenance,
licenses, and patches. `MODULE.bazel` contains every direct source checksum.
Application code should depend on these local labels:

| Label | Built outputs and choices |
| --- | --- |
| `//third_party:krb5` | MIT shared client libraries, profile API in libkrb5, macOS API/CCAPI and KCM backends, stock PKINIT plugin |
| `//third_party:libfido2` | Static FIDO2 library with macOS IOKit HID backend |
| `//third_party:libcbor` | Static CBOR library |
| `//third_party:openssl` | Shared libcrypto and libssl |
| `//third_party:zlib` | Static compression library |

Swift consumers use the corresponding `_swift` labels (for example,
`//third_party:krb5_swift`). These declaration-only wrappers expose generated
upstream headers as Clang modules and preserve each library's Bazel include
paths and linkage. The import names are `CMITKerberos`, `CFIDO2`, `CCBOR`,
`COpenSSL`, and `CZlib`. No library implementation is copied into the wrappers.

libfido2, libcbor, and zlib use upstream CMake with Ninja. MIT and OpenSSL use
upstream configure/Make through rules_foreign_cc. GNU Make is built from the
rules_foreign_cc checksummed archive in Bazel's execution configuration.
CMake and Ninja are checksummed upstream host binaries. CMake's upstream
universal host distribution is not a universal KPasskey release artifact.

MIT retains upstream recursive library ordering: `util include lib` and
`plugins/preauth/pkinit`. This also compiles some supporting/admin libraries
and build utilities, but no KDC, installed authentication CLI, or SSSD daemon.
Only declared client libraries and PKINIT are intended for future packaging;
do not bundle the whole installation tree indiscriminately. The `gen_dir`
filegroups exist for build audit/probe access, not as release manifests.

MIT options: shared libraries, no static MIT copy, required PKINIT (not an
optional configure autodetection), OpenSSL crypto, no TLS transport plugin,
no libedit/readline, no system verto, keyutils, LMDB, translations, host
krb5-config, or absolute runtime search paths. MIT includes its own com_err
and support library. Profile functions are exported by the same libkrb5
runtime. Stock PKINIT includes upstream client and KDC entry points; M1 tests
loadability and symbol presence, not PKINIT/FAST authentication.

OpenSSL options: shared libraries, no external provider modules, no zlib,
no tests, apps, or documentation. The built-in provider remains available.
`OPENSSLDIR` and `MODULESDIR` point to deliberately absent product paths,
never a host install or staging directory. libssl is built as part of the
upstream development install although the selected MIT transport does not
use it. Keeping libcrypto dynamic prevents MIT, PKINIT, and libfido2 from
embedding separate crypto runtimes. Maintaining security updates is a release
responsibility. The OpenSSL pin and its PKINIT compatibility rationale live
in `MODULE.bazel`. No crypto implementation patch or warning suppression
is applied to MIT.

libfido2 options: static library, native HID, no hidapi, PCSC, Windows Hello,
Linux NFC, tools, examples, upstream tests, manpages, or fuzzing. CBOR, crypto,
and zlib include/library inputs are explicit Bazel dependency paths. A small
CMake patch eliminates pkg-config discovery on this macOS build path.
libcbor disables examples, tests, pretty printing, and sanitizers. zlib builds
only its static library, with upstream tests disabled.

All native and foreign target builds share the architecture and deployment
target defined in the build configuration. CMake receives
the toolchain-resolved `SDKROOT`, architecture and minimum version;
configure/Make receives Bazel's Apple compiler/linker flags and the same
SDKROOT/deployment environment. Bazel's derived `DEVELOPER_DIR` also keeps
rules_foreign_cc's direct `xcode-select`/`xcrun` calls on the selected Xcode.
The action PATH contains only macOS utilities. CMake package registries and
host environment searching are disabled; `/opt/homebrew` and `/usr/local`
are excluded. pkg-config and unused regeneration toolchains fail closed;
release tarballs include generated configure/parser files. No Autoconf,
Automake, host CMake, host Ninja, host pkg-config, or Homebrew is needed.

MIT explicitly uses `/usr/bin/ar` and `/usr/bin/ranlib`; the Apple
toolchain's libtool interface does not accept MIT's traditional ar arguments.
MIT generates error-table code through its `compile_et` scripts (awk/sed),
builds internal support/generator programs, and uses the SDK's `mig` for KCM
Mach RPC stubs. OpenSSL uses system Perl plus Perl modules in its
own source archive for configuration, generated headers, and arm64 assembly.
The build is native arm64-to-arm64; it does not pretend that these generators
support cross compilation. Apple compiler, linker, ar/ranlib/libtool, mig,
SDK frameworks, shell/text tools, install_name_tool and codesign are host
prerequisites from macOS/Xcode. None is a shipped third-party target library.

## Linkage and cache compatibility

Bundled: MIT client/support/com_err, OpenSSL, libfido2, libcbor, zlib.
Native: libSystem and SDK libraries/frameworks, the system Swift runtime,
Foundation for test orchestration, IOKit/CoreFoundation for HID, and the legacy
Kerberos framework for CCAPI.
Apple's Kerberos implementation does not replace MIT's ABI.

MIT `src/lib/krb5/ccache/cc_api_macos.c` registers the `API:` cache backend.
It calls legacy CCAPI stubs in Apple's Kerberos framework and, on modern
macOS, contacts `com.apple.GSSCred` using private dictionary keys such as
`command`, `default`, and `kHEIMTypeKerberos`. The XPC service protocol is not
a documented public Apple API. Upstream working code is evidence of a
compatibility path, not a promise of Apple support. The backend also contains
OS-version-specific behavior. M3 validated shared-cache publication and Apple's
system `klist`/`kgetcred` on the development Mac, with the worker joining the
caller's audit session. Other supported OS versions remain deployment checks.
M1's probes neither read nor modify the user's credential cache.

Foreign outputs have canonical, versioned `@rpath` install IDs and sibling
references, rewritten before Bazel publishes the outputs. Symlinks are skipped
and dereferenced installation aliases receive the same canonical ID as the
versioned library. MIT configure programs need a temporary rpath to the
staged OpenSSL library; all foreign rpaths are removed before publication. Modified Mach-O files receive an ad-hoc signature
for arm64 loading; Developer ID signing and notarization are later work.
PKINIT remains a Mach-O bundle. The host supplies matching framework rpaths and
explicit application-owned plugin paths; Bazel runfiles are not product runtime
paths. MIT's compiled configuration/plugin defaults are not product configuration.
Isolated profiles disable external preauthentication/locator modules and select
only the authentication mode's explicitly bundled plugin.

## Verification targets

All test cases use Swift Testing, with shared Swift probe functions and
Foundation process/file APIs replacing the initial C/Objective-C code and shell
drivers. Swift owns cleanup around imported pointer APIs. The OpenSSL
header/runtime check uses the full version string because Swift cannot import
the synthesized numeric macro. Standalone relocation executables share probe
logic without linking test frameworks.

- `//tests:dependency_probe`: an in-memory MIT profile/context, origin check
  for MIT libkrb5, FIDO object allocation without device enumeration, CBOR
  round trip, OpenSSL digest checked against a known SHA-256 value, and zlib
  compression/decompression. `//tests:dependency_app` exercises the shared
  functions as a signed Swift executable.
- `//tests:bridge_probe`: Swift calling the MIT profile/context APIs directly.
  `//tests:bridge_app` also builds that consumer with `rules_apple`'s
  `macos_command_line_application`; the relocation test stages and runs it.
- `//tests:load_probe`: `dlopen(RTLD_NOW)` of stock PKINIT, both init entry
  points present, and the plugin resolving the same MIT context function.
- `//tests:linkage_audit`: arm64/minimum OS on archives, dylibs and PKINIT, closure of
  `@rpath` dependencies, no host/staging library references or absolute rpaths,
  valid ad-hoc signatures (including both Apple command-line applications),
  legacy CCAPI linkage and GSSCred marker present.
- `//tests:relocation_probe`: copy only the declared runtime libraries, PKINIT,
  and both signed Swift command-line applications to a directory with spaces.
  Both executables link with `@executable_path/../lib`; their bytes and
  signatures are checked before running with an empty environment. No rpath
  rewriting or re-signing occurs in the test.

These are build/link/load checks. They do not contact a KDC, enumerate a
security key, test a PIN, obtain a TGT, or establish release readiness.

## Native application

```sh
bazel build --config=development //app:KPasskey
ditto -x -k bazel-bin/app/KPasskey.zip /tmp/kpasskey-native
open /tmp/kpasskey-native/KPasskey.app
```

The app uses the same worker implementation and bundle contents as the console,
with native host/service signing identifiers. The shared `Authentication`
adapter owns presentation and response policy for both real-mode clients.
Settings persist only validated configuration, including the selected public
CA certificate; passwords and PINs remain transient.

`bazel test --config=development //:native` checks shared presentation/secret
validation, settings persistence and the relocated native bundle's XPC identity.
The app's `Contents/MacOS/KPasskey --check-worker` diagnostic negotiates with the
worker and exits without accessing a KDC, key or credential cache. The default
test configuration verifies rejection of ad-hoc peers. The full suite continues
to cover console interactions, dependency closure and plugin loading.

## Distribution work

Extend the M2 application/XPC bundles with authentication resources and the
native UI. Preserve their tested resource placement, nested signatures, and
relocation behavior. Test Hardened Runtime, Developer ID signing, notarization,
stapling and Gatekeeper on clean Macs. Publish archives/DMGs, checksums and
third-party notices on GitHub Releases only after the later release criteria
in NATIVE_PLAN.md are met.
