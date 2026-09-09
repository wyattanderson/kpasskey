# Dependency provenance

`MODULE.bazel` is the source of truth for versions, archive URLs, checksums,
extraction roots, and patches. `MODULE.bazel.lock` records the Bzlmod graph and repository
extension inputs. Hashes are of the downloaded upstream archives; they are
integrity pins, not a claim of independent signature verification.

| Dependency | License / upstream notice | Use |
| --- | --- | --- |
| MIT krb5 | [NOTICE](licenses/MIT-krb5-NOTICE), composite permissive licenses | Shared MIT client runtime, profile API, macOS API cache, stock PKINIT |
| libfido2 | [BSD-2-Clause and component notices](licenses/libfido2-LICENSE) | Static FIDO2 library, macOS HID backend |
| libcbor | [MIT](licenses/libcbor-LICENSE) | Static CBOR library |
| OpenSSL | [Apache-2.0](licenses/OpenSSL-LICENSE) | Shared crypto/SSL libraries; one libcrypto runtime |
| zlib | [Zlib](licenses/zlib-LICENSE) | Static compression library |
| CMake | BSD-3-Clause plus bundled notices in the upstream distribution | Downloaded host tool; not shipped |
| GNU Make | GPL-3.0-or-later, upstream `COPYING` | Built host tool; not shipped |
| Ninja | Apache-2.0, upstream `COPYING` | Downloaded host tool; not shipped |
| rules_foreign_cc | Apache-2.0, upstream `LICENSE` | Builds upstream native dependencies |
| rules_shell / platforms | Apache-2.0, upstream `LICENSE` files | Upstream build-rule shell support and platform constraints |
| rules_cc / rules_apple / rules_swift / apple_support | Apache-2.0, upstream `LICENSE` files | Native language and Apple toolchain rules |

Apple's SDK, frameworks, compiler, system Perl, and system command-line
utilities are build prerequisites governed by their own licenses. They are
not vendored or redistributed here. Transitive build-rule dependencies are
recorded in the lockfile and retain their own upstream licenses. This inventory
does not assign a license to new KPasskey code; settle that before distribution.

The headers under `swift/` contain only includes of the generated upstream
headers. Their Bazel wrappers expose Clang modules to Swift without adding C
implementation code. Required upstream libraries retain their implementation
languages under the policy in [AGENTS.md](../AGENTS.md).

## Patches

- `libfido2-hermetic.patch`: replace pkg-config discovery in the
  non-Windows path with required explicit CBOR, crypto and zlib inputs, and
  require macOS. This overlay is intentionally macOS-only. Remove if upstream
  offers an explicit dependency-injection mode that does not probe the host.
- `krb5-client-build.patch`: allow a top-level-only Make traversal
  override, leaving recursive dependency ordering intact. Build `util`,
  `include`, `lib`, and stock PKINIT; omit server/CLI/test traversal. Remove if
  upstream offers a client-library-only build target with PKINIT.
  It also empties the legacy KDC locator's plugin-directory list. That loader
  ignores the application profile's plugin policy and has no public disabling
  API accessible from Swift. This upstream-only hardening patch prevents host
  locator plugins from overriding explicit KDC/DNS settings; no application
  logic or interoperability shim is written in C. Remove it if upstream exposes
  a supported per-context locator policy.

The libfido2 target undefines Bazel's `_FORTIFY_SOURCE` before upstream sets
its own value, preserving upstream's warnings-as-errors policy. The CMake
compatibility policy floor in `build/foreign.bzl` accommodates upstream's
older minimum requirement. Neither adjustment changes authentication behavior.
