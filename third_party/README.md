# Dependency provenance

Versions were resolved from upstream on 2026-09-05. `MODULE.bazel` is the
source of truth for HTTPS archive URLs, SHA-256 hashes, extraction roots,
and patches. `MODULE.bazel.lock` records the Bzlmod graph and repository
extension inputs. Hashes are of the downloaded upstream archives; they are
integrity pins, not a claim of independent signature verification.

| Dependency | Version | License / upstream notice | Use |
| --- | --- | --- | --- |
| MIT krb5 | 1.22.2 | [NOTICE](licenses/MIT-krb5-NOTICE), composite permissive licenses | Shared MIT client runtime, profile API, macOS API cache, stock PKINIT |
| libfido2 | 1.17.0 | [BSD-2-Clause and component notices](licenses/libfido2-LICENSE) | Static FIDO2 library, macOS HID backend |
| libcbor | 0.14.0 | [MIT](licenses/libcbor-LICENSE) | Static CBOR library |
| OpenSSL | 3.6.4 | [Apache-2.0](licenses/OpenSSL-LICENSE) | Shared crypto/SSL libraries; one libcrypto runtime |
| zlib | 1.3.2 | [Zlib](licenses/zlib-LICENSE) | Static compression library |
| CMake | 4.4.3 | `CMake.app/Contents/doc/cmake/` in pinned archive (BSD-3-Clause plus bundled notices) | Downloaded host tool; not shipped |
| GNU Make | 4.4.1 | GPL-3.0-or-later, `COPYING` in rules_foreign_cc's pinned source archive | Built host tool; not shipped |
| Ninja | 1.13.2 | Apache-2.0, upstream `COPYING` | Downloaded host tool; not shipped |
| rules_foreign_cc | f68b351c4691e747f889dc5e4c2cac3cd3b66ea2 | Apache-2.0, upstream `LICENSE` | HEAD snapshot, archive plus SHA-256 override |
| rules_shell / platforms | 0.8.0 / 1.1.0 | Apache-2.0, upstream `LICENSE` files | BCR version and lockfile pins |
| rules_cc / rules_apple / rules_swift / apple_support | 0.2.22 / 4.5.3 / 3.6.1 / 2.8.1 | Apache-2.0, upstream `LICENSE` files | BCR version and lockfile pins |

Apple's SDK, frameworks, compiler, system Perl, and system command-line
utilities are build prerequisites governed by their own licenses. They are
not vendored or redistributed here. Transitive build-rule dependencies are
recorded in the lockfile and retain their own upstream licenses. This inventory
does not assign a license to new KPasskey code; settle that before distribution.

## Patches

- `libfido2-hermetic.patch`, for 1.17.0: replace pkg-config discovery in the
  non-Windows path with required explicit CBOR, crypto and zlib inputs, and
  require macOS. This overlay is intentionally macOS-only. Remove if upstream
  offers an explicit dependency-injection mode that does not probe the host.
- `krb5-client-build.patch`, for 1.22.2: allow a top-level-only Make traversal
  override, leaving recursive dependency ordering intact. Build `util`,
  `include`, `lib`, and stock PKINIT; omit server/CLI/test traversal. Remove if
  upstream offers a client-library-only build target with PKINIT.

The libfido2 target undefines Bazel's `_FORTIFY_SOURCE` before upstream sets
its own value to 2, preserving upstream's warnings-as-errors policy. CMake's
3.5 compatibility policy floor allows libfido2's older CMake minimum with
CMake 4.4.3. Neither adjustment changes authentication behavior.
