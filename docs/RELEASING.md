# Releases

Distribute the arm64 application as a DMG with `KPasskey.app` on the left and
an Applications folder link on the right. The user drags the app onto the link
to install it. The existing Bazel bundle includes the worker, plugins, libraries,
icons, and license notices; no installer is needed.

## Build and version

Use Bazelisk, full Xcode, and a complete Git checkout with tags. Tool and
dependency pins live in `MODULE.bazel`, `.bazelversion`, and the workflow.
SVU and piñata are checksummed upstream binaries downloaded by Bazel.

```sh
git fetch origin --tags
version=$(bazelisk run //:version)
bazelisk build --embed_label="$version" //:release
```

`//:release` builds the unsigned DMG and checksum from the internal
`//app:KPasskey` ZIP. Its packaging action runs locally without Bazel's sandbox
because Disk Arbitration and Finder must create and arrange the mounted image.
`--embed_label` stamps the selected tag into
`CFBundleShortVersionString` and `CFBundleVersion` in both the app and worker.
The distribution tool rejects a mismatch between either bundle and the release
version. Unstamped local builds use a zero version. There is no version file
to update: stable Git tags are authoritative. Prerelease tags are rejected
because bundle versions use Apple's numeric format.

To bump and create an annotated local tag:

```sh
bazelisk run //:bump
```

This uses [SVU](https://github.com/caarlos0/svu) and Conventional Commits:
`fix:` increments patch, `feat:` increments minor, and breaking changes increment
major. If the commits do not call for a bump, it fails without creating a tag.
For an explicit increment, use `bazelisk run //:bump -- patch`, `minor`, or
`major`. The checkout must be clean and non-shallow. It never pushes; review
the tag and run the exact `git push origin TAG` command printed by the tool.

## Pipeline without signing credentials

The Release workflow builds on an arm64 macOS runner using Bazelisk and the
repository's Bazel pin. Only version-tag pushes and explicit manual runs start
CI. Branch pushes and pull requests do not start macOS runners. Validate ordinary
changes locally; request a manual run when runner-specific behavior needs testing.
Do not push a release tag just to test workflow edits.

Both triggers execute the tests, verify release-policy rejection of ad-hoc peers,
exercise development XPC, build the stamped archive, and upload an unsigned DMG
and SHA-256 checksum. Manual runs stop there and never publish or use signing secrets.
Unsigned means ad-hoc signed for arm64 execution, without Developer ID or
notarization. The release XPC policy remains enabled, so this archive is for
packaging validation and cannot authenticate users.

Pushing a stable version tag also exercises GitHub Release creation. Until
`RELEASE_SIGNING_ENABLED` is exactly `true`, it creates an **unsigned draft
prerelease**. Keep it as a draft. Use a new tag for a later signed release;
existing tags and release assets are never overwritten. Rerunning a tag job
after it has created its release fails instead of replacing it.

Compilation and tests have read-only repository permissions and no signing
secrets. Only the tag publishing job has `contents: write` and uses the
`release` environment. Signing runs through `bazel run`, outside cacheable
build actions, so private keys do not become Bazel inputs or cached artifacts.
The workflow's inline shell only connects GitHub environment values to direct
Bazel/GitHub CLI commands; project-owned release logic is Swift.

## Local iteration and explicit CI

Run the same checks as CI locally before spending runner time:

```sh
bazelisk test --lockfile_mode=error --embed_label=v1.2.3 //...
bazelisk test --lockfile_mode=error --embed_label=v1.2.3 //release:archive_tests
bazelisk test --lockfile_mode=error --config=development //tests:native_app //tests:xpc_integration
```

Use the archive commands above to check packaging. Local Bazel outputs are reused
between invocations; no separate local cache service is needed.

For an explicit runner check, choose **Actions → Release → Run workflow** and
select the branch, or use:

```sh
gh workflow run release.yml --ref YOUR_BRANCH
```

GitHub requires the workflow file to exist on the default branch before manual
dispatch is available. Merge the workflow there before using this command.

CI caches Bazelisk downloads, dependency downloads, and Bazel action outputs
through the pinned setup action. The publishing job restores the build job's
cache without saving another copy. Signing keys and signed distributions remain
outside the cache.

GitHub scopes caches by ref: release tags can restore caches from the default
branch, but cannot restore another tag's cache. An explicit run on the default
branch seeds reusable outputs for later releases; manual runs on a development
branch warm that branch. Cache reuse still depends on matching Bazel action
keys, including the discovered toolchain. See GitHub's
[cache scope rules](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

## Export the signing identity

1. In Xcode Settings → Accounts, add the Apple Account enrolled in the Developer
   Program. Select the team, open Manage Certificates, and create a **Developer
   ID Application** certificate. Apple Development, Apple Distribution, and
   Developer ID Installer certificates are different certificate types.
2. In Keychain Access → My Certificates, find that certificate and expand it
   to confirm its private key is present. Export the certificate **with its
   private key** as a password-protected `.p12` file. A downloaded `.cer` alone
   cannot sign an application.
3. Record the full signing identity shown by
   `security find-identity -v -p codesigning`, including its team identifier.
4. At [Apple Account](https://account.apple.com/), create an app-specific
   password for notarization. Use the enrolled account and its Developer
   Program Team ID. This is separate from the `.p12` export password and
   does not require an App Store listing.

The application currently uses no capability that needs a Developer ID
provisioning profile. No profile, App Store application record, or installer
certificate is needed for this DMG distribution.

## Store GitHub secrets

In the repository's Settings → Environments, create `release`. Restrict its
deployment tags to release tags and configure a required reviewer if available
for your repository plan. Add these **environment secrets**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 of the exported `.p12`, including its private key |
| `APPLE_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: Your Name (TEAMID)` identity |
| `APPLE_ID` | Apple Account email used for notarization |
| `APPLE_TEAM_ID` | Developer Program Team ID |
| `APPLE_APP_PASSWORD` | The app-specific notarization password |

To copy the certificate for the GitHub secret field:

```sh
base64 -i /path/to/DeveloperID.p12 | pbcopy
```

Alternatively, with an authenticated GitHub CLI, stream it directly into the
secret without printing it:

```sh
base64 -i /path/to/DeveloperID.p12 | gh secret set APPLE_CERTIFICATE_BASE64 --env release
gh secret set APPLE_CERTIFICATE_PASSWORD --env release
gh secret set APPLE_SIGNING_IDENTITY --env release
gh secret set APPLE_ID --env release
gh secret set APPLE_TEAM_ID --env release
gh secret set APPLE_APP_PASSWORD --env release
```

The remaining commands prompt for their values. Keep the `.p12` and passwords
out of Git and chat. Base64 is an encoding, not encryption; GitHub's secrets
storage protects the encoded private key. See GitHub's
[certificate secret instructions](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Enable signed releases after keyless validation

Once the unsigned workflow is green and the secrets are installed, set the
`release` environment variable `RELEASE_SIGNING_ENABLED` to `true`. Push a new
stable version tag created by `//:bump`.

To validate signing locally first, set the same six `APPLE_*` environment variables
listed above in your terminal. For the certificate, use
`export APPLE_CERTIFICATE_BASE64="$(base64 -i "$HOME/Desktop/Certificates.p12")"`.
Enter the two passwords privately rather than placing their values in shell
history. Then build and prepare the signed distribution locally:

```sh
version=$(bazelisk run //:version)
bazelisk build --lockfile_mode=error --embed_label="$version" //app:KPasskey
archive=$(bazelisk cquery --lockfile_mode=error --embed_label="$version" --output=files //app:KPasskey)
bazelisk run --lockfile_mode=error //release:prepare -- signed "$archive" dist "$version"
```

This performs the same signing, XPC validation, notarization, and stapling as CI,
including the wait for Apple, without using a hosted runner or publishing a
GitHub release. Use it when signing or packaging changes require a real check;
ordinary app iteration can use the local tests without another notarization.

The publish job imports the identity into a temporary keychain, signs the
bundled libraries and plugins followed by the worker and app, enables Hardened
Runtime and secure timestamps, and checks the real signed XPC connection.
It submits a temporary app ZIP to Apple, requires notarization acceptance,
staples the ticket to the app, validates Gatekeeper acceptance, and creates the
final DMG and checksum. The temporary keychain and certificate are removed.
Signing or notarization failure stops publication; it never falls back to unsigned mode.

The final DMG is made after stapling the application. See Apple's
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [signing requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
Before distributing to users, test the downloaded archive on a clean supported
Mac, including offline launch and real authentication; CI does not contact a KDC
or exercise a physical FIDO key.

Once Apple has received an upload, stopping the local command or CI job does not
cancel Apple's processing. Keep the submission ID; use `xcrun notarytool info`
or `xcrun notarytool wait` with that ID and the same Apple account/team to check
it from your Mac, instead of uploading it again. `notarytool history` lists past
submissions if the ID was not recorded. These commands can prompt privately for
the app-specific password when supplied with `--apple-id` and `--team-id`.
Resuming status checks does not resume a canceled packaging job: stapling and
archiving still require the original signed app. See `xcrun notarytool submit --help`
for its timeout behavior, and Apple's notarization workflow linked above.

## Update action pins

After choosing action versions in the workflow, run:

```sh
bazelisk run //:pin_actions
```

This runs [piñata](https://github.com/caarlos0/pinata) over `.github/workflows`,
replacing action tags with full commit SHAs and preserving version comments.
Review and commit the resulting workflow diff. Tool updates belong in Bazel's
dependency configuration, not a separate host package installation.
