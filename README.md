# KPasskey

A native macOS application for acquiring FreeIPA Kerberos tickets with USB
FIDO2 security keys. The intended experience is a global shortcut, a small
native authentication window, and tickets available to existing macOS Kerberos
consumers.

Distribution will be a relocatable, Developer ID-signed and notarized `.app`
bundle published on GitHub Releases. End users must not need Homebrew, a
terminal, a domain join, or a manually maintained `krb5.conf`.

## Status

Milestone 1 implements arm64 macOS dependency builds with Bazel, Swift probes
and Swift Testing, signed `rules_apple` command-line applications, PKINIT
loading, linkage checks, and relocation tests. Milestone 2 adds shared Swift XPC
contracts, a client adapter, an embedded fake worker, and a console host app with
lifecycle and peer-identity tests. Milestone 3 adds password authentication,
automatic DNS realm/KDC discovery, configurable forwardable tickets and shared
macOS cache publication, validated live with Apple's `klist` and `kgetcred`.
Milestone 4 adds the Swift passkey plugin, libfido2 adapter, anonymous PKINIT
armor and harness interactions. Offline validation passes; live passkey login
and the hardware matrix remain pending in PLAN.md. The first native menu-bar
app adds sign-in, settings, secure prompts and last-published ticket details.
See [NATIVE_PLAN.md](NATIVE_PLAN.md) for build/run instructions and the remaining
shortcut, login-item, live ticket monitoring and distribution work.

See [docs/BUILD.md](docs/BUILD.md) for Xcode setup,
dependency choices, and clean reproduction. Run `bazel test //...` after
installing Xcode and completing its first-launch setup. Run
`bazel test --config=development //...` to exercise the ad-hoc signed XPC peers;
the default configuration checks that release policy refuses those peers.

Start with [PLAN.md](PLAN.md), which defines the milestone order and acceptance
criteria. Supporting documents describe:

- [Architecture and XPC contract](docs/ARCHITECTURE.md)
- [Application-owned Kerberos configuration](docs/CONFIGURATION.md)
- [Bazel dependencies, native libraries, and release packaging](docs/BUILD.md)
- [FreeIPA protocol and assertion implementation](docs/PROTOCOL.md)

## Decisions

- Swift is the primary and mandatory language for all project-owned code,
  including tests, tools, the worker, harness, adapters, and plugin logic.
  Use modern Swift tooling, with Swift Testing mandatory for automated tests
  unless a required testing capability is unavailable. C or Objective-C is
  allowed only where it is **absolutely and functionally necessary**, with a
  documented Swift interoperability limitation and the smallest possible shim.
  Calling a C library or implementing an Objective-C-compatible protocol is
  not itself an exception. See [AGENTS.md](AGENTS.md) for the full policy.
- Write a purpose-built MIT krb5 client preauthentication plugin.
- Use `../macos-passkey` as a behavioral reference, not a source dependency.
  Preserve compatibility with the FreeIPA KDC protocol, **not** with the old
  command line, helper protocol, build system, configuration, or internal APIs.
- Keep MIT krb5 and libfido2. Do not implement Kerberos, CTAP, USB HID framing,
  or cryptographic primitives ourselves.
- Use a bundled, unprivileged XPC worker and a shared native client interface.
  The future UI and an earlier command-line harness use the same worker path.
- Use Bazel with Bzlmod external repositories. Use `rules_apple` for macOS
  application and XPC bundles, and `rules_swift` for Swift compilation and tests.
  Keep upstream dependencies in their upstream languages and build configuration
  in Bazel; the Swift requirement applies to our implementation.
- Prefer supported native macOS libraries where practical. A bundled OpenSSL
  dependency is acceptable; eliminating it must not become a prerequisite.
- Configure Kerberos through typed application settings and library APIs.
- Apple/iCloud passkeys, AuthenticationServices passkey integration, the Mac
  App Store, login integration, and privileged system services are out of scope.

## Planned source layout

The authentication packages and initial native UI exist; release work remains:

```text
app/             SwiftUI/AppKit menu-bar application and settings
xpc/             Contracts/client, password/passkey worker, MIT/FIDO adapters, console
passkey/         Swift PA-REDHAT-PASSKEY plugin, wire format and protocol tests
third_party/     External repository metadata, BUILD overlays, patches
build/           Shared Bazel macros, platforms, packaging support
tests/           Fixtures, build probes, XPC and integration tests
release/         Signing/notarization automation and release documentation
```

Keep this directory independently buildable. Do not require sibling source
trees, lab credentials, absolute checkout paths, or Homebrew libraries.
