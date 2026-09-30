# Mixoto

A native macOS audio mixer with separate Monitor and Stream controls for apps and microphones. No Elgato hardware, OBS, or BlackHole is required.

## Build and run

```sh
sh scripts/build-app.sh
open artifacts/Mixoto.app
```

Requires macOS 15+ and Xcode or compatible Swift tools.

### Release

Publish a GitHub release with a `v1.2.3` tag, or run the **Release Mixoto**
workflow manually. `.github/workflows/release.yml` runs the tests, builds a
universal app signed with the Developer ID certificate, and uploads
`Mixoto_<version>_universal.dmg` after Apple notarizes it. It uses the same
organization secrets as Jean: `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
`APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD` and `APPLE_TEAM_ID`.

## Use

1. Install the bundled virtual device from the app. Administrator access is required; audio stops briefly.
2. Add an app or microphone channel. Grant recording access when prompted.
3. Select headphones for Monitor and **Mixoto Stream Mix** as the input in your recording or call app.

Use headphones to prevent microphone feedback. Live audio routing is not yet fully verified.

## Docs

- [Virtual device setup and removal](docs/virtual-device.md)
- [Verification](docs/verification.md)
- [Driver and license](Driver/README.md)
