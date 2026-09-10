# Native KPasskey application

Milestones 1–4 provide the implementation foundation. Native application work
starts here; [PLAN.md](PLAN.md) retains the authentication evidence and outstanding
live hardware acceptance. Advancing the UI does not turn offline tests into
proof of successful live passkey authentication.

## Product and implementation

Build a small native menu-bar application that obtains a FreeIPA Kerberos ticket
with an enrolled USB security key, or explicitly selected password sign-in.
Use SwiftUI scenes, forms, secure fields and system controls, with AppKit where
macOS window activation and file selection need it. Preserve native appearance,
keyboard navigation, VoiceOver labels, and light/dark mode.

Reuse the embedded worker, typed settings, plugin packaging and peer policy.
Keep interaction and result decisions in the shared client adapter, used by both
the app and real-authentication console harness. Authentication stays in the
worker; a read-only MIT cache adapter runs off the main thread for live status.
The UI never invokes FIDO, a shell authentication command or an external helper. Secrets
belong only to the current prompt and response; never save them in settings or
log them. SwiftUI/Foundation/XPC copies prevent a universal erasure guarantee.

Use the existing Bazel rules and toolchain configuration. Keep all project-owned
executable code and tests in Swift; use Swift Testing. Dependency pins, platform
selection and deployment targets stay in the build configuration.

## N1 — First usable native app

- [x] Add a signed development `KPasskey.app` target, embedding the existing
  worker implementation, native libraries and authentication plugins.
- [x] Give the native app and its embedded service explicit signing identities;
  retain the harness identities and strict development/release peer checks.
- [x] Add a menu-bar item, one reopenable sign-in window, native settings and Quit.
- [x] Share the observable authentication session with the real-mode console:
  operation ownership, prompt consumption, secure response validation, progress,
  cancellation, terminal results and actionable error descriptions.
- [x] Support password entry, device selection, PIN entry, touch and onboard
  verification guidance. Closing the authentication window cancels pending work.
  Consume a prompt before awaiting its response; late replies must not erase a
  newer prompt or change the final result. Do not retry credentials automatically.
- [x] Persist validated non-secret settings. Offer account, realm, discovery
  domain, authentication mode, RP, CA selection and ticket preference controls.
  Import the existing settings format for explicit KDCs and advanced options.
- [x] Show shared macOS ticket status, principal, cached authentication method
  and expiry, including credentials acquired outside this app.
- [x] Validate the native bundle and shared interaction/settings tests in both
  development and default-policy builds; retain the harness regression suite.
- [x] Exercise launch, reopen, settings, a password prompt and window-close
  cancellation in the graphical app using a synthetic account without submitting
  credentials. Inspect the native sign-in layout in dark mode.
- [ ] Complete password/PIN submission, hardware interaction, keyboard, VoiceOver
  and light/dark visual acceptance.

The initial settings form intentionally exposes the common controls; imported
settings retain the complete typed configuration. Add advanced controls when
those options need to be edited interactively. No additional package manager,
UI dependency, account database, password storage or automatic retry is needed.

Both full Bazel suites pass (`bazel test --config=development //...` and
`bazel test //...`). Native relocation checks verify nested signatures, service
discovery in a separate process with an empty environment, rejection of a
differently signed imposter and default-policy rejection of ad-hoc code. The
full run also exposed a preexisting plugin test that compared JSON key ordering;
it now checks decoded content while retaining the byte-exact opaque-state check.

## N2 — Everyday menu-bar experience

- [ ] Register a global shortcut with native macOS APIs; make it configurable,
  report registration conflicts, and show/focus the same sign-in window.
- [ ] Add optional launch at login using ServiceManagement and show the system's
  actual enabled/approval-required state. Default off; remove registration when
  disabled. Recheck behavior after bundle relocation and upgrades.
- [x] Read the shared cache on launch, wake, activation and refresh independently
  of the authentication worker. Observe external cache changes with Apple's
  Darwin notification and a tolerant safety refresh. Distinguish no ticket,
  expired ticket and inaccessible cache; update the menu-bar pill at expiry
  boundaries without rescanning the cache.
- [ ] Verify window-close, Quit, sleep/wake and fast repeated sign-in behavior.
  Keep cancellation bounded; once publication has committed, its terminal result
  wins over cancellation intent. Transport loss during commit remains unknown.
- [ ] Finish keyboard shortcuts, focus restoration, VoiceOver announcements,
  long account/device labels and appearance/accessibility checks.

## N3 — Live authentication acceptance

- [ ] Repeat live password and passkey authentication from the native app and
  verify the published TGT using system Kerberos consumers.
- [ ] Complete the remaining FreeIPA/key/firmware/UV coverage from PLAN.md.
  Exercise absent, multiple, wrong and removed keys; wrong PIN; onboard UV;
  timeout; cancellation; worker loss and restart. Simulate lockout states rather
  than consuming a real key's remaining PIN attempts.
- [ ] Prove failed/cancelled operations preserve unrelated tickets, settings
  snapshots remain isolated and publication failures are distinguishable from
  authentication failures. Verify secrets stay out of logs and persisted data.
- [ ] Repeat after moving the complete app to a path containing spaces, with no
  shell environment or external Kerberos configuration dependency.

## N4 — Distribution

- [ ] Validate on a clean Mac without Homebrew and on the oldest supported macOS.
  Test every advertised CPU architecture; build configuration defines the current
  scope. Recheck the upstream legacy macOS shared-cache compatibility path.
- [ ] Sign nested executable code with Developer ID, enable Hardened Runtime,
  verify XPC authorization with the release identity and audit entitlements.
- [ ] Notarize, staple and assess Gatekeeper acceptance after downloading and
  relocating the finished bundle. Test both fresh install and upgrade.
- [ ] Add final application icon, third-party notices and licensing review.
- [ ] Publish a signed archive or DMG, checksums, third-party notices and the
  supported macOS/CPU matrix on GitHub Releases.

Release only after live hardware, clean-machine, signing and distribution
acceptance passes. A successful development build is not release acceptance.

## Build and run

See [docs/BUILD.md](docs/BUILD.md) for prerequisites and clean reproduction.

```sh
bazel build --config=development //app:KPasskey
ditto -x -k bazel-bin/app/KPasskey.zip /tmp/kpasskey-native
open /tmp/kpasskey-native/KPasskey.app
```

Use Settings to enter your account and realm, select the authentication method,
and supply RP/CA trust for security-key authentication. Save, then Sign In.
Development signing is explicitly opt-in; the default policy rejects ad-hoc
peers and requires real release signing to authenticate.
