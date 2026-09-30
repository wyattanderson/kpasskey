# Building and releasing

Use an Apple Silicon Mac, full Xcode with its first-launch setup completed, `bazel` on your `PATH`, and a complete Git checkout with tags. The selected developer directory should point to full Xcode, not Command Line Tools. Build and dependency pins live in [.bazelversion](../.bazelversion) and [MODULE.bazel](../MODULE.bazel); Bazel handles the dependencies.

For local setup with Homebrew:

```sh
brew install bazelisk
bazel --version
```

This installs Bazelisk as the `bazel` launcher, which downloads and runs the version selected by `.bazelversion`. Run the version check from the repository root. If you install Bazel another way, ensure `bazel` is on your `PATH` and matches `.bazelversion`. GitHub Actions uses `setup-bazel` to install the launcher as `bazel`; its `bazelisk-*` inputs configure installation and caching.

## Build for your own Mac

From the repository root:

```sh
bazel build --config=development //app:KPasskey
kpasskey_build=$(mktemp -d)
ditto -x -k bazel-bin/app/KPasskey.zip "$kpasskey_build"
open "$kpasskey_build/KPasskey.app"
```

This produces an ad-hoc signed app that can authenticate locally without an Apple developer account. `--config=development` allows the app and its bundled worker to trust the local build. Without it, the release policy rejects ad-hoc peers. Omit this flag when building for distribution.

Run both policies' tests when changing the app:

```sh
bazel test --lockfile_mode=error //...
bazel test --lockfile_mode=error --config=development //...
```

For a fresh build without previous compiled outputs or user Bazel settings:

```sh
kpasskey_output_base=$(mktemp -d)
bazel --nosystem_rc --nohome_rc --output_base="$kpasskey_output_base" fetch --lockfile_mode=error //...
bazel --nosystem_rc --nohome_rc --output_base="$kpasskey_output_base" test --nofetch --lockfile_mode=error //...
```

## Make a release

Start with a clean checkout and complete history, including remote tags:

```sh
git fetch origin --tags
bazel run //:bump
```

This creates an annotated local tag using Conventional Commits: `fix:` bumps patch, `feat:` bumps minor, and a breaking change bumps major. For an explicit increment, use `bazel run //:bump -- patch` (or `minor` or `major`). Tags use `vMAJOR.MINOR.PATCH`; there is no version file to edit and prerelease suffixes aren't supported.

To check the stamped disk image locally before pushing:

```sh
version=$(bazel run //:version)
bazel build --lockfile_mode=error --embed_label="$version" //:release
bazel test --lockfile_mode=error --embed_label="$version" //release:archive_tests
```

The DMG and checksum are under `bazel-bin/release/`. This is an unsigned packaging check: the release policy is still enabled, so this app can't authenticate until it has been signed with a trusted identity. Disk image creation uses Finder and may request Automation permission.

Review the tag, then run the exact `git push origin TAG` command printed by `//:bump`. The [Release workflow](../.github/workflows/release.yml) tests, builds, signs, notarizes, and publishes the DMG when signing is enabled. Existing releases aren't overwritten; publish corrections under a new tag.

Without signing enabled, a tag push creates an unsigned draft prerelease. Keep it as a draft. For a CI check without publishing, use **Actions → Release → Run workflow**. Manual runs don't use signing credentials or publish releases; ordinary branch pushes and pull requests don't start the workflow.

## Set up or rotate signing credentials

1. Using your Apple Developer Program account, create a **Developer ID Application** certificate in Xcode's account settings or through [Apple's certificate portal](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
2. In Keychain Access, export the certificate **and its private key** as a password-protected `.p12`. A downloaded `.cer` alone isn't enough. Find the full identity with `security find-identity -v -p codesigning`.
3. Create an [app-specific password](https://support.apple.com/en-us/102654) for notarization. This is separate from the `.p12` password.
4. In GitHub's repository settings, create the `release` environment, restrict it to release tags, and add the environment secrets below. Set its environment variable `RELEASE_SIGNING_ENABLED` to `true` when ready to publish signed releases.

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `.p12`, including the private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: Your Name (TEAMID)` identity |
| `APPLE_ID` | Apple Account email used for notarization |
| `APPLE_TEAM_ID` | Developer Program Team ID |
| `APPLE_APP_PASSWORD` | App-specific notarization password |

Use `base64 -i /path/to/DeveloperID.p12 | pbcopy` to copy the certificate into the secret field. Keep the `.p12` and passwords out of Git; base64 still contains the private key. GitHub also documents [certificate storage for Actions](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

For rotation, replace the affected secrets and validate a locally signed build before publishing a new tag. A replacement certificate from the same team needs no code change. Revoking an old Developer ID certificate can prevent previously signed apps from running; Apple's [certificate guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) explains the effect.

## Sign and notarize locally

Export the same six `APPLE_*` values above into your terminal environment. For the certificate, use `export APPLE_CERTIFICATE_BASE64="$(base64 -i /path/to/DeveloperID.p12)"`; enter passwords privately, without saving them in shell history. Then run:

```sh
version=$(bazel run //:version)
bazel build --lockfile_mode=error --embed_label="$version" //app:KPasskey
archive=$(bazel cquery --lockfile_mode=error --embed_label="$version" --output=files //app:KPasskey)
bazel run --lockfile_mode=error //release:prepare -- signed "$archive" dist "$version"
```

This uses a temporary keychain, signs the app and nested code, checks the signed XPC connection, waits for notarization, and staples Apple's ticket before creating the DMG and checksum in `dist/`. It doesn't publish to GitHub. Signing credentials stay outside Bazel's cacheable build actions, and signing or notarization failure stops the process.

Before distributing a release, test the downloaded DMG on a clean supported Mac, including offline launch, authentication with a real key and KDC, and ticket use by a native Kerberos client. Automated tests don't cover that whole path.
