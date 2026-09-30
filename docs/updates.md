# App updates

Mixoto uses [Sparkle 2.10.0](https://sparkle-project.org/documentation/) for app
updates. Signed release builds check the stable feed automatically, normally
once per 24 hours. Use **Mixoto > Check for Updates…** for a manual check.
Use **Check for Updates Automatically** in the same menu to turn scheduled
checks off or on. Sparkle saves this preference.

The default is to notify the user, not silently install updates. Installing an
app update quits and restarts Mixoto, which interrupts its audio routing.
Download and feed signatures are checked before installation.

The stable feed is:
https://github.com/coollabsio/Mixoto/releases/latest/download/appcast.xml

GitHub's latest release URL excludes drafts and prereleases. Each stable release
must contain both its DMG and `appcast.xml`. There can be a short period after
release publication when the workflow has not uploaded these files yet.

## Driver updates are separate

An app update replaces the driver copy inside the app, not the installed driver
in `/Library/Audio/Plug-Ins/HAL`. If a release changes the driver, use
**Mixoto > Reinstall Virtual Device…** after updating the app. That separate
action requires administrator approval and restarts Core Audio. The app updater
does not run the privileged installer.

## One-time release setup

The release workflow requires an Ed25519 key pair in addition to the existing
Apple signing and notarization secrets. Generate this pair once on a trusted Mac:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mixoto
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mixoto -p
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mixoto -x /secure/path/mixoto-update-key
```

In the repository's **Settings > Secrets and variables > Actions**:

- Set repository variable (or secret) `SPARKLE_PUBLIC_ED_KEY` to the public key printed by
  `generate_keys`. The build embeds this value as `SUPublicEDKey`.
- Set repository secret `SPARKLE_PRIVATE_ED_KEY` to the complete contents of the
  exported private-key file. Do not commit or log this file. Keep a secure backup
  and remove the working export after setup.

Do not generate a new key for each release. Existing apps trust the key embedded
in their bundle. See Sparkle's [key rotation instructions](https://sparkle-project.org/documentation/#rotating-signing-keys)
if that key must change.

The workflow builds and signs the app and Sparkle's nested helpers, notarizes the
DMG, then signs the DMG and feed with Sparkle's tools. It uploads both assets to
the selected release. A missing key, mismatched key, or missing archive signature
fails the workflow. `CFBundleVersion` and `CFBundleShortVersionString` both use
the release version. Publish stable versions in increasing order.

The current pre-updater app cannot acquire this feature by itself. Users must
install the first updater-enabled release manually from
[GitHub Releases](https://github.com/coollabsio/Mixoto/releases/latest).

## Local builds and tests

Local builds without `SPARKLE_PUBLIC_ED_KEY` have disabled update controls and
make no update requests. Developer ID builds require the public key. Smoke tests
disable the updater even if a key is present.

```sh
swift test
sh scripts/test-updater.sh
```

The script uses temporary test keys, builds an ad-hoc signed universal app,
generates a signed feed, verifies signatures and tamper rejection, rejects a
mismatched key, and runs the native-window smoke test. It does not use Keychain,
install a driver, restart Core Audio, or publish files. It restores a normal
local app build after the test.

Before production use, test an older and a newer Developer ID signed, notarized
release: check for updates from the menu, install the offered update, and verify
the new version after restart. Test automatic-check preferences, offline errors,
and driver reinstall when a driver change is part of the release. A local
signature test does not prove a notarized end-to-end update works.

Setup follows the current [SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/#create-an-updater-in-swiftui)
and [update settings](https://sparkle-project.org/documentation/customization/).
