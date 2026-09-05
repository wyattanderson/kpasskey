# Bazel dependencies and macOS distribution

## Build policy

Use Bzlmod for dependency declarations. Pin rule versions, external source
archives/commits and integrity hashes, and the Bazel version. Commit the module
lockfile and maintain a documented Xcode/SDK baseline. Apple SDKs remain an
explicit platform prerequisite; no claim of a fully SDK-independent build.
Version selection and successful builds are milestone 1 work, not completed by
the minimal repository scaffold. See [Bazel external dependencies](https://bazel.build/external/overview).

Prefer upstream foreign build systems initially through
[rules_foreign_cc](https://bazel-contrib.github.io/rules_foreign_cc/), with local
Bazel labels insulating application code from archive layouts. Native BUILD
overlays are an option when evidence shows they simplify maintenance. Every
patch needs a reason, upstream version, and removal/update condition.

## Dependency inventory to resolve

| Component | Purpose | Initial integration direction |
| --- | --- | --- |
| MIT krb5 | Client protocol, FAST, profile APIs, cache backend | Upstream release configure/Make via Bazel; required client libraries and stock PKINIT |
| libfido2 | FIDO2 USB assertions and PIN protocol | Upstream CMake via Bazel; macOS HID backend |
| libcbor | libfido2's CBOR dependency | Pinned external repository |
| OpenSSL/libcrypto | libfido2 and likely stock PKINIT crypto | Bundle supported upstream dependency as needed |
| zlib | Required by the selected libfido2 build | Evaluate SDK/system zlib first; explicit linkage |
| JSON parser | Small preauth wire format | Choose established implementation; Jansson remains acceptable |
| rules_cc / rules_swift | C, Objective-C, Swift integration | Compatible pinned rules and toolchains |
| rules_apple | App and XPC service bundles | Native macOS bundle rules |
| Build tools | Configure, Make, CMake, Ninja/pkg-config as needed | Declared tool inputs or documented, pinned prerequisites |

This is an inventory, not a final closure. Audit transitive dependencies and
generated host tools for the actual versions/configurations chosen. Release
archives may avoid requiring Autoconf regeneration; do not accidentally build
or execute a target-architecture generator as a host tool.

## Native libraries and crypto

Prefer Foundation/AppKit/SwiftUI, XPC, Security/Keychain, and the supported macOS
HID APIs for their appropriate responsibilities. Retain libfido2's platform
backend rather than writing USB/CTAP transport. The current upstream build
uses libcbor, libcrypto, and zlib; establish the exact closure at our pinned
revision. [libfido2 build definition](https://github.com/Yubico/libfido2/blob/main/CMakeLists.txt)

Using macOS crypto facilities in application-owned code does not automatically
replace OpenSSL underneath MIT PKINIT or libfido2. Use an existing supported
backend if available; do not create a crypto port merely to eliminate a bundled
library. Removing unused algorithms/features is reasonable only after checking
interoperability. Expect to maintain OpenSSL security updates if we ship it.

Do not substitute Apple's Kerberos implementation for MIT's client engine:
we need the MIT clpreauth interface. Any Apple framework use by MIT's macOS
cache backend must be identified and validated separately. Keep linkage to
Apple and MIT Kerberos APIs unambiguous.

## Build risks to close in milestone 1

- Foreign builds must receive the same target architecture, SDK, deployment
  target and compiler policy as Bazel's native Apple targets.
- Supply explicit include/library/pkg-config paths from Bazel dependencies;
  prevent accidental Homebrew or system-installed package discovery.
- Declare generated headers, archives, dylibs, module artifacts and transitive
  framework dependencies as outputs/inputs. Avoid network fetches in actions.
- Make built-in/plugin registration and static/dynamic linkage deliberate.
  A dynamically loaded plugin must bind to the worker's intended MIT runtime,
  not a second incompatible static copy or Apple's same-named symbols.
- Audit MIT plugin-directory and PKINIT resource defaults. Runtime paths must
  resolve within the relocated bundle or worker-owned resources.
- Inspect Mach-O dependencies and rpaths. No runtime `/opt/homebrew`, `/usr/local`,
  build execroot, output-base, staging-prefix, or developer-checkout references.
- Treat arm64 and x86_64 as separate builds if both are supported; assemble
  universal artifacts only after both dependency closures pass validation.

## Apple bundles

Use rules_apple's `macos_application` and `macos_xpc_service` with rules_swift
where appropriate. Prove embedding and service discovery with the console
host in milestone 2. Build resource placement through bundle rules instead of
post-build scripts that accidentally invalidate signatures. Consult the pinned
release's [macOS rule documentation](https://github.com/bazelbuild/rules_apple/blob/main/doc/rules-macos.md)
for attributes; these target names alone do not constitute a working build.

Conceptual runtime contents:

```text
KPasskey.app/Contents/
  MacOS/          application executable
  XPCServices/    authentication worker.xpc
  Frameworks/    bundled dynamic dependencies where appropriate
  PlugIns/       application-owned plugin bundles/modules as appropriate
  Resources/     metadata, notices, approved resources
```

Finalize exact nested placement/rpaths with the rule implementation and signing
validation. Runtime discovery uses bundle locations, never the current working
directory or Bazel runfiles in distributed artifacts.

## Distribution

GitHub Releases is the selected channel; Mac App Store eligibility is not a
milestone. Ship a conventional relocatable `.app` in an archive or DMG rather
than insist on a literal single Mach-O executable.

Separate reproducible build inputs from signing credentials and notarization
secrets. Sign nested executables, plugins and libraries with the appropriate
identity, then their containing bundles. Enable Hardened Runtime; keep library
validation enabled unless a concrete need is demonstrated. Only our bundled
plugin is loaded. Use Apple's notarization flow and staple the resulting ticket
to supported artifacts. [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Verify signatures, Gatekeeper behavior and fresh download/relocation on a clean
Mac without Homebrew. Publish architecture/OS requirements, dependency notices,
checksums and reproducible source references. Track dependency licensing and
provenance before importing code; a rewrite does not relicense copied sources.
