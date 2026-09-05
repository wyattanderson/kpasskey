# Bazel dependency builds

Milestone 1 builds dependencies and exercises C, Objective-C, and dynamic
loading. It does not implement a worker, UI, passkey plugin, or authentication.

## Pinned baseline

Only **arm64 macOS** is supported. The deployment target is **macOS 14.0**;
x86_64 and universal release artifacts are not requirements.

| Input | Pin |
| --- | --- |
| Bazel | 8.8.0 (`.bazelversion`) |
| Apple Command Line Tools | package `com.apple.pkg.CLTools_Executables`, 26.6.0.0.1781586589 |
| macOS SDK | 26.5, `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` |
| Apple clang | 21.0.0, build `clang-2100.1.1.101` |
| Host Perl | Apple `/usr/bin/perl`, 5.34.1 |
| apple_support | 2.8.1, registered before rules_cc for Objective-C support |
| rules_cc | 0.2.22 |
| rules_apple | 4.5.3 |
| rules_swift | 3.6.1 |
| rules_shell / platforms | 0.8.0 / 1.1.0 |
| rules_foreign_cc | HEAD at 2026-09-05: `f68b351c4691e747f889dc5e4c2cac3cd3b66ea2` |
| CMake / Ninja / GNU Make | 4.4.3 / 1.13.2 / 4.4.1 |

The tested host is macOS 26.6.2 (25G83). Full Xcode is **not required for
these M1 probes**: apple_support supports Command Line Tools. The baseline
explicitly selects CLT, rather than claiming an untested full-Xcode version.
The Bzlmod graph pins rules_apple/rules_swift for subsequent milestones; app
bundling and Swift compilation are not validated by these Objective-C probes.
Select and validate full Xcode when implementing M2 bundles. Testing execution
on macOS 14 itself remains part of later deployment/release validation.

Install the exact Command Line Tools from Apple's developer downloads and
select `/Library/Developer/CommandLineTools` using `xcode-select` if necessary.
`build/check_prerequisites.sh` checks the baseline without changing the machine.
The Apple SDK/compiler and macOS utilities are documented host inputs, not a
claim of a completely hermetic or SDK-independent toolchain.

## Reproduce

Install the official [Bazel 8.8.0 arm64 binary](https://github.com/bazelbuild/bazel/releases/tag/8.8.0),
verify its release checksum, and put it on PATH or set `BAZEL` to its absolute
path. Bazelisk also honors `.bazelversion`. Homebrew is not needed.

From the repository root:

```sh
./build/check_prerequisites.sh
bazel test //...
```

For a new output base with no previously compiled artifacts:

```sh
BAZEL=/absolute/path/to/bazel-8.8.0-darwin-arm64 ./build/reproduce.sh
```

The script ignores user/system bazelrc files, creates a fresh output base,
fetches `//...` with the committed lockfile, then tests `//...` with `--nofetch`
and `--lockfile_mode=error`. Repository downloads occur during fetch only.
Build actions use the Darwin sandbox with network access disabled. A shared
Bazel repository download cache may satisfy checksummed fetches; there is no
shared action cache in the fresh output base. The script leaves the output
base and logs available for inspection.

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
| `//third_party:krb5` | MIT 1.22.2 shared client libraries, profile API in libkrb5, macOS API/CCAPI and KCM backends, stock `pkinit.so` |
| `//third_party:libfido2` | libfido2 1.17.0 static archive with macOS IOKit HID backend |
| `//third_party:libcbor` | libcbor 0.14.0 static archive |
| `//third_party:openssl` | OpenSSL 3.6.4 shared libcrypto and libssl |
| `//third_party:zlib` | zlib 1.3.2 static archive |

libfido2, libcbor, and zlib use upstream CMake with Ninja. MIT and OpenSSL use
upstream configure/Make through rules_foreign_cc. GNU Make is built from the
rules_foreign_cc checksummed 4.4.1 archive in Bazel's execution configuration.
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
responsibility; OpenSSL 3.6.4 is the newest maintained 3.x release. The newer 4.0.2
was tested and rejected because stock MIT 1.22.2 PKINIT accesses ASN.1
structures made opaque in 4.x and uses APIs with changed const qualifiers.
No crypto implementation patch or warning suppression is applied to MIT.

libfido2 options: static library, native HID, no hidapi, PCSC, Windows Hello,
Linux NFC, tools, examples, upstream tests, manpages, or fuzzing. CBOR, crypto,
and zlib include/library inputs are explicit Bazel dependency paths. A small
CMake patch eliminates pkg-config discovery on this macOS build path.
libcbor disables examples, tests, pretty printing, and sanitizers. zlib builds
only its static library, with upstream tests disabled.

All native and foreign target builds use arm64 and macOS 14.0. CMake receives
the explicit SDK, architecture and minimum version; configure/Make receives
Bazel's Apple compiler/linker flags and the same SDKROOT/deployment environment.
The action PATH contains only macOS utilities. CMake package registries and
host environment searching are disabled; `/opt/homebrew` and `/usr/local`
are excluded. pkg-config and unused regeneration toolchains fail closed;
release tarballs include generated configure/parser files. No Autoconf,
Automake, host CMake, host Ninja, host pkg-config, or Homebrew is needed.

MIT explicitly uses `/usr/bin/ar` and `/usr/bin/ranlib`; the Apple
toolchain's libtool interface does not accept MIT's traditional ar arguments.
MIT generates error-table code through its `compile_et` scripts (awk/sed),
builds internal support/generator programs, and uses the SDK's `mig` for KCM
Mach RPC stubs. OpenSSL uses the pinned system Perl plus Perl modules in its
own source archive for configuration, generated headers, and arm64 assembly.
The build is native arm64-to-arm64; it does not pretend that these generators
support cross compilation. Apple compiler, linker, ar/ranlib/libtool, mig,
SDK frameworks, shell/text tools, install_name_tool and codesign are host
prerequisites from macOS/CLT. None is a shipped third-party target library.

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
  profile/context APIs from a C executable.
- `//tests:load_probe`: `dlopen(RTLD_NOW)` of stock PKINIT, both init entry
  points present, and the plugin resolving the same MIT context function.
- `//tests:linkage_audit`: arm64/minimum OS on archives, dylibs and PKINIT, closure of
  `@rpath` dependencies, no host/staging library references or absolute rpaths,
  valid ad-hoc signatures, legacy CCAPI linkage and GSSCred marker present.
- `//tests:relocation_probe`: copy only the declared runtime libraries, PKINIT,
  and C probe to a directory with spaces, replace the executable's Bazel
  rpaths with a bundle-relative rpath, re-sign, and execute with an empty
  environment.

The final clean reproduction on 2026-09-05 completed 71 actions (28 Darwin
sandbox processes) in 138.8 seconds, with all five tests passing after fetch.
`git diff --check` and shell syntax checks also passed.

These are build/link/load checks. They do not contact a KDC, enumerate a
security key, test a PIN, obtain a TGT, or establish release readiness.

## Later bundle and distribution work

Use rules_apple application/XPC rules and rules_swift when M2 begins. Finalize
resource placement and nested signatures through bundle rules. Test relocation
including spaces, Hardened Runtime, Developer ID signing, notarization,
stapling and Gatekeeper on clean Macs. Publish archives/DMGs, checksums and
third-party notices on GitHub Releases only after the later release criteria
in PLAN.md are met.
