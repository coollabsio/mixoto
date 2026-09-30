# Mixoto Stream Mix

## Current task

- [x] Read current Apple virtual audio driver sample and installed HAL SDK contracts.
- [x] Build one stereo Mixoto Stream Mix driver; keep Apple's source and license unmodified.
- [x] Connect the Stream graph by stable UID. Remove OBS/BlackHole as required routes. Monitor can be off.
- [x] Add an explicit Install/update button and driver build/install/uninstall scripts. No automatic root installation, default-device changes, or reboot.
- [x] Verify local bundle loading, driver properties, PCM loopback, multiple readers, ring wrap/reset, and simulated impulse delay.
- [x] Run Address/UndefinedBehavior/Thread Sanitizers; Swift and delay tests; release build, signature, bundled-driver matching, and native window launch.
- [ ] Administrator install/update/uninstall and cancellation flow. Restart macOS and verify public HAL discovery.
- [ ] Live source capture and virtual-input recording, stop/restart/quit cleanup, Bluetooth, sleep/wake, and 30-minute sessions.
- [ ] Measure real reference-to-return delay. Current 42.666667 ms probe is offline simulated callbacks, not live system audio.
- [ ] Helper-process mapping, automatic reconnect, limiter, meters, and gain ramps remain unfinished.

- [x] Auto-start on launch; live add/remove/reassign channels and Monitor change without Stop (incremental router apply). Removed Stream Mix note box.
- [ ] Live-verify hot add/remove with real app + mic sources; Captured stayed 0 with AirPods mic in user test (cause unknown).

- [x] Permanent System channel: global tap excluding Mixoto + assigned apps/helpers.
- [x] App channels capture helper processes (bundle prefix); tap rebuilt when helper set changes.
- [ ] Live-verify System channel and Helium helper capture; Safari/WebKit audio comes from com.apple.WebKit.GPU and is not mapped to Safari.

- [x] User-renamable Stream Mix device (driver 0.3.0: settable name, host storage, PropertiesChanged; UID fixed).
- [ ] Live-verify rename after reinstall: Audio MIDI Setup/OBS show new name, OBS source still bound, name survives coreaudiod restart.

## Design

One source per channel, one microphone at a time. The existing Stream bus sums all assigned sources with their Stream gains/mutes. Monitor remains a separate optional graph. The HAL device exposes one stereo input and one output transport, not an aggregate of unprocessed sources. Name: Mixoto Stream Mix. UID: local.mixoto.stream-mix. Stereo float32 / 48 kHz. Hide the Apple sample's demonstration controls; app controls own the mix.

Transport uses a fixed 16,384-frame tagged ring and a 2,048-frame read offset. Missing/expired frames are silent; independent readers do not consume data. The PCM path uses lock-free 64-bit atomics, with no allocation or blocking locks. Device clock/lifecycle callbacks use mutexes. App capture still allocates and scheduling still uses locks. No hard real-time or zero-latency promise.

Installer copies only our signed bundle to /Library/Audio/Plug-Ins/HAL/MixotoAudio.driver, after user action and macOS administrator authorization. It refuses unknown/linked target bundles. Installation and removal restart coreaudiod (killall; launchd relaunches) so the driver loads/unloads without a reboot. System audio stops briefly. Do not install during automated tests.

## Documentation and source

No WebSearch tool was available. Read current Apple DocC/sample data on 2026-09-30 and verify ABI against the installed macOS 27 SDK on macOS 26.6.2.
- https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
- https://docs-assets.developer.apple.com/published/430ad6501f6f/CreatingAnAudioServerDriverPlugIn.zip
- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- https://developer.apple.com/documentation/avfaudio/avaudioengine
- https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice

AppleSample/NullAudio.c SHA-256: 8b61fb9f96c12356c7da6696a6c1bee5da73222dfb4e831aa9487244e7bf5dfc. Source matches the downloaded sample. License included in source and bundle.

## Review

16 Swift tests and four Python tests pass. Local CFPlugIn tests load the actual signed driver and verify its published identity/format, I/O contract, two readers, stale-frame handling, reset and clock seed. ASan/UBSan and TSan ring tests pass. Six-pulse driver WAV analysis reports median/p95 42.666667 ms in a simulated callback timeline. The separate 37.5 ms fixture verifies only analysis-tool correctness.

Release app and driver build and verify; embedded driver binary matches the standalone build. Native window smoke confirms both installer and driver resources are bundled and the native UID is selected. System driver is not installed, no recording access was requested, and no live sound routing was claimed. See docs/verification.md and docs/virtual-device.md.

GitHub issue/discussion search is unavailable: no Git remote. No external item is claimed fixed. Keep changes uncommitted unless requested.

## Mixoto rename

- [x] Rename app, package, driver, identifiers, scripts, tests, and docs.
- [x] Preserve old settings and safely replace the old driver during explicit installation.
- [x] Build and test Swift, driver, delay analysis, signatures, and native launch.
- [x] Check old-name references and GitHub issue/discussion availability; record results.

Use Mixoto for display names and mixoto for identifiers. Keep Apple sample source unchanged. Do not modify installed drivers, user settings, or the workspace directory during verification.

### Rename review

Mixoto.app, MixotoAudio.driver, local.mixoto.app, local.mixoto.audio, and
local.mixoto.stream-mix are consistent across source, metadata, scripts, tests,
and docs. Custom driver symbols use MX; Apple sample source stays unchanged.
Only migration code, tests, and the migration guide retain the old name.
Removed obsolete generated app/driver bundles, not installed system bundles.

22 Swift tests, four delay tests, driver contract/PCM checks, ASan/UBSan/TSan,
release build, signatures, bundled binary comparison, shell syntax checks, and
native window launch pass. Isolated installer checks cover unknown/linked legacy
rejection, replacement, update, and uninstall isolation. Native smoke reports
Mixoto, the new UID, bundled driver/installer, and audio stopped.

The old system driver is installed; the new one was not installed during tests.
No Core Audio restart, user settings write, or live audio test was performed.
The existing CFString pointer compiler warning in Devices.rename remains.
GitHub issue/discussion search is unavailable because there is no Git remote;
no fully fixed, related, or similar external item is claimed.

## Driver installation counters

- [x] Clear Captured and Dropped blocks when stopping for install/reinstall.
- [x] Do not update counters while the driver installer is busy.
- [x] Test stopped/busy counter behavior; rebuild and verify native launch.

The router already destroys output buses on stop, which clears its underlying
counts. Clear the published UI values too, including after cancellation/failure.
Do not restart Core Audio or run privileged installation during tests.

### Counter reset review

The router discards its output buses on stop. MixerStore now clears published
Captured/Dropped blocks at the same time, even when already stopped, and skips
counter polling while installation is busy. Install/reinstall already uses stop
before authorization; cancellation/failure also resumes from fresh buses.
24 Swift tests pass, including stopped/running reset and busy polling tests.
Release build, signatures, and native launch pass. No privileged install or
Core Audio restart was run. Live install/reinstall counter checks remain manual.
GitHub issues/discussions are unavailable: no Git remote. No external item is
claimed fully fixed, related, or similar.

## Remove repeated mixer heading

- [x] Remove the in-content app title and description.
- [x] Keep start/stop, keyboard shortcut, and accessibility in the Outputs row.
- [x] Run tests, release build, and native launch; check repository discovery.

### Heading removal review

Removed the repeated app title and description from MixerView. Outputs now
starts the content; start/stop stays at the right of the Monitor row with its
Space shortcut, busy-state guard, help, and accessibility label unchanged.
24 tests, release build/signatures, and native window launch pass. Manual visual
and start/stop checks remain available; no live audio test was run.
GitHub issue/discussion search is unavailable because there is no Git remote.
No external item is claimed fully fixed, related, or similar.

## Follow default monitor output

- [x] Add a persisted Default system output picker option; retain Off and fixed devices.
- [x] Resolve the Core Audio default output and observe default-output changes.
- [x] Rebuild only Monitor when its resolved device changes; refuse loopback outputs.
- [x] Test resolution/persistence, run all tests/build/smoke, and record results.

Use `kAudioHardwarePropertyDefaultOutputDevice`, not the system-alert output
property. Persist a sentinel, not the resolved device UID. Keep Off as the initial
setting and never change the system default. Missing or loopback defaults disable
Monitor with an error, without falling back to another device.
Apple reference: https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice
No WebSearch tool is available. Current Apple DocC and the installed SDK confirm
the selector returns the default output AudioObjectID.

### Default output review

Default system output persists as system-default, not the current device UID.
MixerStore reads and observes the playback-default selector; changes reapply the
router. Monitor compares the resolved device ID/UID, so following the default
does not rebuild every refresh. A changed Monitor does not discard a healthy
Stream bus. Off and explicit device selections retain their behavior. Recognized
loopback and missing defaults are rejected without fallback.

27 Swift tests, release build/signatures, and native window launch pass. Tests
cover default changes, saved sentinel, fixed/off selections, missing defaults,
input-only devices, and current/legacy/BlackHole loopback rejection. Actual
System Settings changes during playback need manual verification. No system
default, driver installation, or audio-service restart was changed during tests.
GitHub issues/discussions are unavailable: no Git remote. No external item is
claimed fully fixed, related, or similar.

## Debug counters popover

- [x] Hide capture/drop counts behind a debug icon and a native popover.
- [x] Keep errors visible and live/reset counter behavior unchanged.
- [x] Run tests/build/native launch and record results.

Use local SwiftUI state for presentation, a ladybug icon with help/accessibility,
and the existing observable counters. Do not persist a debug setting or change
audio behavior. Apple DocC verified the binding-based popover API (no WebSearch
tool available): https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:)

### Debug popover review

The bottom-right ladybug button opens debug information with the existing live
Captured/Dropped counters. Counts are hidden by default; native popover dismissal
does not change audio or counter state. Errors remain in the footer. Help and an
accessibility label describe the icon. 27 Swift tests, release build/signatures,
and native window launch pass. Opening/dismissing the popover needs manual UI
verification. GitHub issues/discussions are unavailable: no Git remote. No
external item is claimed fully fixed, related, or similar.

## Plain debug icon

- [x] Remove glass button styling; use a plain secondary-colored icon.
- [x] Verify tests, release build, native launch, and repository discovery.

Keep click behavior, help, accessibility, and popover unchanged.

### Plain icon review

Debug icon now uses plain styling, without glass/background/border. Native
Button semantics preserve activation/accessibility. 27 tests, release build,
signatures, and native launch pass. Manual visual/popover check remains. GitHub
issues/discussions unavailable: no Git remote; no external matches claimed.
