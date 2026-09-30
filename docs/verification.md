# Verification record

Date: 2026-09-30. Host: macOS 26.6.2, Apple Silicon. Swift 6.4; macOS 27 SDK.

## Stages

Previous stage: 12 Swift tests passed. Current virtual-device stage: 16 Swift
tests pass, plus local driver bundle and sanitizer tests.
Three final repeated Swift test runs also pass. The app bundle contains the
current signed driver and installer. Its smoke report selects the native UID
and reports `streamDeviceLoaded: false`: the system driver is not installed.
Four Python tests pass. The release app builds; signature and Info.plist checks
pass. The final native launch report has two channels and nine discovered
devices, with audio stopped. No audio driver or recording permission was changed.

1. **Controls:** model tests verify persistence, gains/mutes, valid sources, and
   route constraints. Device discovery finds headphones and microphones.
2. **Audio graph:** offline rendering verifies actual PCM amplitudes for bus
   gains, mute isolation, summing, and bounded scheduling. Tests cover planar
   and interleaved stereo, mono conversion, and 44.1 → 48 kHz conversion.
3. **Live routing:** process taps and microphone routing are implemented.
   Actual permission, aggregate clocks, playback, and cleanup tests remain
   pending. The native virtual driver is built but not installed in HAL.
4. **Delay:** a known synthetic 37.5 ms delay is detected. Missing return
   pulses, silence, and negative delay are rejected. Hardware delay is not measured.

Offline players start after buffers are scheduled so test alignment does not
depend on host time. Converter startup priming is retained; rate conversion
tests check the total frame ratio across multiple blocks.

The native launch smoke test does not start audio, request recording access,
record speech, or read/write saved settings. It reports a visible window and
channel/device counts. It does not prove audio routing or visual rendering.
An AppKit bitmap snapshot failed to render native controls correctly and was
not accepted as visual verification. That snapshot is not part of the test.

## Native virtual device stage

- The actual signed driver bundle loads with CFPlugIn in a local test process.
- Tests discover one stereo device and check its name, stable UID, translation,
  fixed 48 kHz format, stream/control lists, read-only controls and clock.
- Tests verify output-to-input PCM, multiple readers, stale-frame silence,
  first-start silence, stop/reset, and a new timestamp seed after restart.
- Ring tests check wraparound and concurrent readers/writer under Address,
  UndefinedBehavior, and Thread Sanitizers.
- An impulse returns 2,048 frames later in the offline transport. This is
  42.666667 ms at 48 kHz; it is not measured live device or total path delay.
- Six pulses through simulated callbacks of the actual driver produce an
  offline WAV. The delay tool measures median and p95 at 42.666667 ms. No
  hardware or system audio was captured for this test.
- Swift tests verify the summed Stream graph, native device UID recognition,
  Monitor-off route validation, missing-driver failure without capture, and
  installer path quoting.

Pending: privileged installation, macOS audio-server loading after reboot,
installer cancellation, live input recording, driver upgrade/removal, and
long-session behavior. A loaded local test bundle is not a registered HAL device.

## Repeat automated checks

```sh
rtk swift test
rtk proxy sh scripts/test-driver.sh
rtk proxy python3 scripts/test-delay.py
rtk proxy sh scripts/build-app.sh
rtk proxy env MIXOTO_SMOKE_REPORT="$PWD/artifacts/smoke.json" \
  artifacts/Mixoto.app/Contents/MacOS/Mixoto
rtk proxy cat artifacts/smoke.json
rtk proxy codesign --verify --strict artifacts/Mixoto.app
rtk git diff --check
```

Expected: no test failures; smoke report has `running: false`, two channels,
and a visible native window. It also has `driverBundled: true`,
`installerBundled: true`, and `streamDeviceUID: local.mixoto.stream-mix`.
`streamDeviceLoaded` remains false until administrator installation and reboot.
The smoke process then exits.

## Live checks — pending

- [ ] Inspect native labels, pickers, sliders, resizing, channel removal, and
      settings persistence after normal app relaunch.
- [ ] Deny microphone/system audio recording access. Start must fail with a
      clear error and no remaining tap or private aggregate.
- [ ] Allow microphone access. Test the selected microphone at low volume on
      headphones. Verify Monitor gain and mute.
- [ ] Play a direct-output app. Verify captured audio, suppression of original
      playback, mute isolation, pause/resume, and playback restoration on Stop.
- [ ] Repeat Start/Stop ten times. Verify tap/aggregate cleanup and no memory growth.
- [ ] Quit during capture. Verify original playback returns and resources are removed.
- [ ] Click Install… (or Mixoto > Reinstall Virtual Device…). Test administrator cancellation
      and success. After the automatic Core Audio restart, verify Audio MIDI Setup lists one stereo
      Mixoto Stream Mix device. No default sound output should change.
- [ ] Record this virtual input in a normal audio-input app. Verify all
      unmuted Stream channels are summed, and Monitor mute does not change it.
- [ ] Stop/restart the mixer while a recorder stays connected. Silence must
      replace old data, without stale-buffer playback.
- [ ] Test driver update and uninstall, then reboot and check device discovery.
- [ ] Disconnect the selected output/mic. Stop rather than use a different device.
- [ ] Quit/relaunch a source app. The channel must reconnect by itself; do not reuse stale process IDs.
- [ ] Test browser/Electron helper audio separately; support is unfinished.
- [ ] Run a 30-minute recording; check drops, drift, memory, and glitches.
- [ ] Test sleep/wake, AirPods, wired headphones, and sample-rate changes.
- [ ] Measure physical/virtual-input reference-return pulses. Keep WAVs, device names,
      sample rates, median, p95, range, and test conditions.

## Delay results

| Route | Median | p95 | Meaning |
| --- | --- | --- | --- |
| Synthetic fixture | 37.5 ms | 37.5 ms | Analysis correctness only |
| Application → headphones | Not measured | Not measured | Live test pending |
| Microphone → headphones | Not measured | Not measured | Live test pending |
| Stream → virtual input | Not measured live | Not measured live | Driver not installed |
| Driver transport only | 42.666667 ms | Fixed | Offline impulse shift, not end-to-end |

## GitHub discovery

Issue lookup and repository discovery were attempted with the installed GitHub
CLI. Both reported no Git remote. Issue/discussion search is unavailable; no
item is claimed as fully fixed, related, or similar.

## Mixoto rename verification

22 Swift tests and four delay tests pass. Renamed driver bundle contract tests
and ASan/UBSan/TSan transport tests pass. Release build, signatures, shell syntax,
and bundled driver binary comparison pass. The native smoke window is titled
Mixoto and reports three channels, the new `local.mixoto.stream-mix` UID, bundled
driver/installer, and `running: false`. The old system driver remains installed;
Mixoto's driver is not loaded until explicit administrator installation.

Settings tests verify legacy fallback, current-file preference, invalid current
file handling, and preservation of the old file. Legacy UID recognition prevents
using the old virtual device as a source or as the new Stream Mix output.
Isolated installer checks used temporary HAL folders and stubbed privileged
commands: unknown/linked legacy bundles are refused; verified legacy replacement,
updates, and uninstall isolation pass. No system audio service was restarted.
Real administrator migration and receiving-app device selection remain pending.

## Driver installation counter reset

24 Swift tests pass. Regression tests verify that stopping clears Captured and
Dropped blocks for running and already-stopped mixers, that polling cannot
restore discarded counts, and that polling is suspended while installation is
busy. Release build, signatures, and native launch pass.

Manual check: accumulate captured blocks, then install/reinstall the virtual
device. Both counts must clear before authorization and stay zero during
installation. After capture resumes, only the new session is counted. Repeat
with administrator cancellation and while the mixer is already stopped.
Core Audio interruption and privileged installation were not run automatically.

## Follow default Monitor output

27 Swift tests pass, plus release build/signature and native launch checks.
Resolution tests verify changes between two defaults, saved selection, fixed
device behavior, Off, unavailable defaults, input-only devices, and recognized
loopback rejection. The router reuses healthy Monitor buses when the resolved
ID/UID is unchanged. Store observes the playback-default output selector.

Manual check: choose Default system output with low-volume audio and no live
microphone. Change the output in System Settings > Sound between headphones
and speakers. Monitor must follow; Stream Mix must keep its independent route.
Select a fixed device and repeat: Monitor must stay on that device. Relaunch
to verify the choice is saved. Use headphones for microphone tests; switching
to speakers can cause feedback. Live default switching was not automated.

## Debug information popover

27 Swift tests, release build/signatures, and native window launch pass. Counters
now appear only in the bottom-right debug icon's popover. Manual check: click
the ladybug icon, verify live Captured/Dropped counts, click outside to dismiss,
and reopen. Error messages must remain visible in the footer. Counter reset
and installation polling rules are unchanged. Popover interaction was not
automated.
