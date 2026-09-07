# Bazel dependency builds

Milestone 1 builds dependencies and exercises C, Objective-C, and dynamic
loading. It does not implement a worker, UI, passkey plugin, or authentication.

## Setup

Only arm64 macOS is supported. The platform and minimum deployment target
are defined in the Bazel configuration; x86_64 and universal releases are not
requirements. `.bazelversion`, `MODULE.bazel`, and `MODULE.bazel.lock` record
the build-tool and dependency versions.

Install Xcode and complete its first-launch setup, including license
acceptance. `.bazelrc` selects `/Applications/Xcode.app` with repository and
action `DEVELOPER_DIR` settings so native and foreign builds use the same
installation even when the machine-wide `xcode-select` setting points to
Command Line Tools. Bazel discovers Xcode's version and default SDK; neither
is pinned. If Xcode lives elsewhere, override both
`--repo_env=DEVELOPER_DIR=...` and `--action_env=DEVELOPER_DIR=...`.

The bridge uses `rules_apple` to link and ad-hoc sign a macOS command-line
application. App/XPC bundling, Swift compilation, and execution on the oldest
supported macOS remain later milestone validation.
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
disabled. rules_apple marks its `SignBinary` action `no-sandbox`, so that
mnemonic alone uses the local strategy for ad-hoc signing. A shared
Bazel repository download cache may satisfy checksummed fetches; there is no
shared action cache in the fresh output base. The output base and logs remain
available for inspection. No prerequisite or reproduction wrapper is required.

When deliberately updating pins, run `bazel mod deps --lockfile_mode=update`,
then `bazel test //...`, review the lockfile, and rerun the clean reproduction.
Do not turn the HEAD override into a moving branch reference: resolve a new
commit and checksum explicitly.

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
SDKROOT/deployment environment. The action `DEVELOPER_DIR` setting also keeps
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
Native: libSystem and SDK libraries/frameworks, Foundation for the bridge,
IOKit/CoreFoundation for HID, and the legacy Kerberos framework for CCAPI.
Apple's Kerberos implementation does not replace MIT's ABI.

MIT `src/lib/krb5/ccache/cc_api_macos.c` registers the `API:` cache backend.
It calls legacy CCAPI stubs in Apple's Kerberos framework and, on modern
macOS, contacts `com.apple.GSSCred` using private dictionary keys such as
`command`, `default`, and `kHEIMTypeKerberos`. The XPC service protocol is not
a documented public Apple API. Upstream working code is evidence of a
compatibility path, not a promise of Apple support. The backend also contains
OS-version-specific behavior. M3 must test actual shared-cache publication
and system consumers on the supported OS versions. M1 neither reads nor
modifies the user's credential cache.

Foreign outputs have canonical, versioned `@rpath` install IDs and sibling
references, rewritten before Bazel publishes the outputs. Symlinks are skipped
and dereferenced installation aliases receive the same canonical ID as the
versioned library. MIT configure programs need a temporary rpath to the
staged OpenSSL library; all foreign rpaths are removed before publication. Modified Mach-O files receive an ad-hoc signature
for arm64 loading; Developer ID signing and notarization are later work.
PKINIT remains a Mach-O bundle. Future bundles must provide matching framework
rpaths and an explicit application-owned plugin path; Bazel runfiles are not
product runtime paths. MIT's compiled configuration/plugin defaults are not
product configuration. M3/M4 must supply isolated profiles and explicit paths.

## Verification targets

- `//tests:dependency_probe`: an in-memory MIT profile/context, origin check
  for MIT libkrb5, FIDO object allocation without device enumeration, CBOR
  round trip, OpenSSL digest, and zlib compression/decompression.
- `//tests:bridge_probe`: Objective-C/Foundation bridge calling the same MIT
  profile/context APIs from a C executable. `//tests:bridge_app` also builds
  that entry point and bridge with `rules_apple`'s
  `macos_command_line_application`; the relocation test stages and runs it.
- `//tests:load_probe`: `dlopen(RTLD_NOW)` of stock PKINIT, both init entry
  points present, and the plugin resolving the same MIT context function.
- `//tests:linkage_audit`: arm64/minimum OS on archives, dylibs and PKINIT, closure of
  `@rpath` dependencies, no host/staging library references or absolute rpaths,
  valid ad-hoc signatures (including the Apple command-line application),
  legacy CCAPI linkage and GSSCred marker present.
- `//tests:relocation_probe`: copy only the declared runtime libraries, PKINIT,
  C probe and Apple command-line application to a directory with spaces.
  The C probe's Bazel rpaths are replaced and it is re-signed; the Apple
  executable already links with `@executable_path/../lib` and is verified
  and run without modification. Both execute with an empty environment.

These are build/link/load checks. They do not contact a KDC, enumerate a
security key, test a PIN, obtain a TGT, or establish release readiness.

## Later bundle and distribution work

Extend the current rules_apple command-line build with application/XPC rules
and rules_swift when M2 begins. Finalize
resource placement and nested signatures through bundle rules. Test relocation
including spaces, Hardened Runtime, Developer ID signing, notarization,
stapling and Gatekeeper on clean Macs. Publish archives/DMGs, checksums and
third-party notices on GitHub Releases only after the later release criteria
in PLAN.md are met.
