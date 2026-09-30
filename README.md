# Mixoto

A native SwiftUI mixer for macOS Tahoe. No Elgato hardware is required.
The app now includes its own Stream Mix virtual audio driver. OBS and BlackHole
are not required. Live system routing remains unverified.

## Build and open

```sh
rtk swift test
rtk proxy sh scripts/test-driver.sh
rtk proxy python3 scripts/test-delay.py
rtk proxy sh scripts/build-app.sh
rtk proxy open artifacts/Mixoto.app
```

The build needs Xcode or compatible Swift tools. Verification uses Swift 6.4,
the installed macOS 27 SDK, and a macOS 26.6.2 runtime. APIs require macOS 15 or
later; other macOS versions were not tested. Use the app bundle, not the raw
package executable, for its privacy descriptions and stable bundle identifier.
The app is locally signed. It is not notarized for distribution.

## Implemented

- Create, rename, remove, and save channels. Assign one running application or
  microphone to each channel. Only one microphone channel is supported.
- A permanent **System** channel captures all other audio on the Mac: every
  process except Mixoto and apps (with bundle-prefixed helpers) assigned to
  other channels. It is rebuilt, with a short gap, when those assignments change.
- Independent Monitor and Stream volume/mute controls, each with a live peak
  level meter (-60 to 0 dBFS, after that mix's gain and mute; display refresh rate, 30 dB/s fall).
- Core Audio process taps request `.mutedWhenTapped` to suppress original
  process playback while capture is active. No video capture is used.
- Selected mono/stereo microphone capture and stereo 48 kHz conversion.
- Separate `AVAudioEngine` mix graphs, with explicit output selection.
- Monitor output to a fixed device, **Default system output**, or Monitor off.
  Default follows the Mac’s playback output when it changes; fixed devices stay fixed.
- One **Mixoto Stream Mix** virtual input combines all assigned sources,
  using their Stream gains and mutes. Any audio-input app can select it.
- Bundled HAL driver and an explicit administrator installation button.
- Scheduled audio is bounded to 200 ms per source and bus. Incoming and dropped
  blocks are counted (click the debug icon to view them). This bound is **not an end-to-end delay measurement**.
- The mixer starts when the app opens. Add, remove, and reassign channels, or
  change Monitor output, while it runs; unchanged channels keep playing.
  Failed routes are rebuilt; a channel that cannot start shows its reason.

Settings: `~/Library/Application Support/Mixoto/settings.json`.
The driver is installed only after the user starts installation and grants
administrator access. No system default audio device is changed.

## First audio test

Install the bundled driver first; the installer restarts Core Audio. See
[the virtual device guide](docs/virtual-device.md).

1. Set Monitor to Off, or use low-volume headphones. Do not test microphone monitoring on speakers.
2. Leave Monitor off, or select headphones under **Monitor headphones**.
3. Add a channel; select a microphone or running app. Start app playback first.
4. Set channel gains low. The mixer is already running. Grant microphone or system audio
   recording access when macOS asks. If denied, check System Settings > Privacy
   & Security, then restart the app.
5. Click the debug icon and check that **Captured** increases. This counts blocks, not signal level.
6. Test Monitor gain and mute. After Stop, original app playback must return.

Do not select the receiving app or another audio router as a source: this can create feedback.
An app channel also captures its helper processes when their bundle ID starts
with the app's (for example `net.imput.helium.helper` for Helium, as in
Chromium browsers). Safari/WebKit audio comes from a shared
`com.apple.WebKit.GPU` process and is not mapped to Safari; it goes to System.

## Virtual Stream Mix

The **Mixoto Stream Mix** device has a stereo input containing the combined
Stream graph. It is not an extra source channel to create and is not an
aggregate of raw application streams. Muting a channel in Stream excludes its
sound; Monitor mute does not change the virtual input.

1. Click **Install…** in the built app. To update later, choose **Mixoto > Reinstall Virtual Device…**.
2. Grant administrator access. Core Audio restarts; audio stops for a few seconds.
3. The status must say **Mixoto Stream Mix — available**.
4. Assign sources. The mixer is already running. Monitor can stay off.
5. Select **Mixoto Stream Mix** as the input in any recording or call app.

Only Mixoto should write to this device's output. Other writers can add sound
and bypass channel controls. Do not assign an audio router or its receiving app
as a source. The device stays installed when the mixer closes; its input becomes
silent after the buffered tail.

[Install, use, and remove the device](docs/virtual-device.md).
[Driver design and Apple sample license](Driver/README.md).

## Unfinished and unverified

| Area | Status |
| --- | --- |
| Native controls and saved model | Implemented; model tests and native window launch pass |
| Mix graph and conversion | Verified by offline PCM tests |
| Live process taps, private aggregate clocks, original-output suppression and restore | Implemented; live verification pending |
| Live microphone → headphones | Implemented; live verification pending |
| Native Stream Mix input | Driver built and tested locally; system loading and live recording pending |
| Driver installation/update/removal | Implemented; administrator and reboot flow not yet tested |
| Browser/Electron/helper-process mapping | Helpers with a bundle-ID prefix; not Safari/WebKit |
| Automatic reconnect/app restart | Device/app lists update automatically; an app channel reconnects when the app plays audio again |
| Limiter, meters, gain ramps | **Not implemented**; summing can clip, abrupt gains can click |
| Allocation-free capture | **Not implemented**; conversion allocates and scheduling uses locks |
| Long sessions, drift, Bluetooth, sleep/wake | Not verified; drops/glitches are possible |
| Physical/virtual-input end-to-end delay | **Not measured** |

Complete [the live checks](docs/verification.md) before an important recording or call.

## Measure delay

```sh
rtk proxy python3 scripts/measure-delay.py recording.wav
```

Use a real stereo 16-bit PCM recording: left = reference, right = routed return.
Both channels must use the **same recording clock**. Record at least six short,
isolated pulses, one second apart, after at least 50 ms of silence. Avoid
clipping. The driver adds a configured 2,048-frame shift (42.7 ms at 48 kHz), verified
by an offline impulse test. This is not total audio delay.
A physical headphone test needs simultaneous reference/return
capture, for example with a two-input recording interface. No Elgato device is
required. A virtual-input test also needs a recorded reference on the same time base.

The tool reports individual peak delays, median, p95, range, and sample
resolution. Use pulses, not speech/music. Echoes or altered pulse shapes can
bias the result. Sample resolution is not measurement accuracy. Report the
complete reference-to-return path, including capture and hardware delay.
If you subtract a bypass measurement, record its method and uncertainty.

Measure application → headphones, microphone → headphones, and Stream → virtual input
separately. Record device names, sample rate, wired/Bluetooth transport, and
test conditions. No physical delay has been measured in this session.
The 37.5 ms synthetic test fixture proves the analysis tool only; it is **not
this Mac's measured delay**.

## Current Apple sources

Read from Apple's current DocC data on 2026-09-30 and checked against the SDK.
No WebSearch tool was available.

- [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps): capture, private aggregates, process mute, and audio recording permission.
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription).
- [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine): playback graphs and offline tests.
- [Current audio device](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice): explicit selection/read-back.
- [AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter) and [priming](https://developer.apple.com/documentation/avfaudio/avaudioconverter/primeinfo): startup blocks can be shorter; converter state is retained.
- [Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in): current sample used for HAL boilerplate, with Mixoto transport and identity overrides. Apple license is preserved.

ScreenCaptureKit was evaluated first. Process taps replaced it because they
can suppress original app playback without video capture.

## GitHub discovery

Issue/discussion search was unavailable: this repository has no Git remote.
No external item is claimed as fixed.

## Rename from OpenMixer

Mixoto reads existing `~/Library/Application Support/OpenMixer/settings.json`
only if the Mixoto settings file does not exist. Future saves use the Mixoto
folder; the old file stays unchanged. The Stream Mix route uses the new UID.

Explicit driver installation replaces a verified `local.openmixer.audio` bundle
at `/Library/Audio/Plug-Ins/HAL/OpenMixerAudio.driver` with the Mixoto driver.
It refuses unknown or linked legacy bundles. Core Audio restarts only after the
authorized installation. Select **Mixoto Stream Mix** again in receiving apps.
The new app identifier can require new recording permissions. Quit the old app
before opening Mixoto. No installed app or driver is changed by a build.

## Default Monitor output

Choose **Default system output** under **Monitor headphones** to follow the Mac's
current playback output, including later changes in System Settings. The choice
is saved; existing fixed-device selections and Off are unchanged. Mixoto never
changes the system default. If the default is missing or a recognized loopback
device, Monitor stops with an error rather than selecting a different output.
Stream Mix remains separate. Switching Monitor can cause a short playback gap.
Use low-volume headphones with microphones: the default can become speakers
when headphones disconnect, which can cause feedback.
