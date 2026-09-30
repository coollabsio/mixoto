# Mixoto Stream Mix driver

The driver exposes one public stereo audio device:

- Name: **Mixoto Stream Mix**.
- UID: `local.mixoto.stream-mix`.
- Input: the combined Stream mix, for any application that accepts audio input.
- Output: the transport endpoint used by Mixoto's Stream graph.
- Format: 48 kHz, two interleaved float32 channels.
- No driver volume, mute, or data-source controls. Use the app's per-channel controls.
- Cannot be the default system sound output. Can be selected as an input.

This is a summed left/right mix, not an aggregate device with one input per
source. Every assigned source feeds Stream with its own gain and mute. Monitor
uses a separate graph and can be disabled without stopping Stream Mix.

## Apple sample

`AppleSample/NullAudio.c` is an unmodified copy of Apple's current published
sample, retrieved on 2026-09-30. Its license is preserved in
`AppleSample/LICENSE.txt` and in the built driver resources. No BlackHole code
is included. The sample provides the COM interface and HAL object boilerplate.
`MixotoDriver.c` changes identity, exposed properties, clock and I/O through
interface overrides. Example sample controls are not exposed or writable.

- [Current Apple documentation](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in).
- [Published sample ZIP](https://docs-assets.developer.apple.com/published/430ad6501f6f/CreatingAnAudioServerDriverPlugIn.zip).
- ABI and callback contracts were checked against the installed macOS 27 SDK
  `AudioServerPlugIn.h`. Verification host: macOS 26.6.2, Apple Silicon.

## Buffering

`Loopback.c` stores absolute sample-frame tags and stereo pairs in a fixed
16,384-frame ring. One HAL `WriteMix` operation publishes the mixed output;
multiple input clients read without consuming it. Missing, overwritten, or
pre-start frames return silence. Reset occurs only with all I/O stopped.

The read path selects frames 2,048 samples earlier. This supplies scheduling
headroom; at 48 kHz it is **42.666667 ms**. Input device latency reports these
2,048 frames. The clock timestamp period is 512 frames. The HAL owns actual
client buffer sizes; driver callbacks accept up to 4,096 frames.

The offline impulse test verifies the 2,048-frame shift. This is not a measured
end-to-end delay. Actual HAL scheduling, capture conversion, client buffering,
and clock drift can add delay or cause missing frames. Large I/O buffers and
long sessions still need live verification.

The PCM callback has no allocation, logging, or blocking locks. Stereo pairs
and frame tags use lock-free 64-bit atomics. Clock and lifecycle callbacks use
mutexes. This does not make the app's capture/scheduling path allocation-free.

## Build and test

```sh
rtk proxy sh scripts/build-driver.sh
rtk proxy sh scripts/test-driver.sh
```

Tests load the actual signed `.driver` with CFPlugIn in a local test process;
they do not register it with the macOS audio server. Tests cover factory and
device discovery, stable UID translation, fixed formats, hidden controls,
latency, timestamps, multiple readers, startup/reset, stale-frame silence,
and PCM preservation. Ring tests run with Address/UndefinedBehavior Sanitizers
and Thread Sanitizer. These checks do not prove installation or live routing.
The test also creates `artifacts/driver-offline-probe.wav` from six pulses
passed through the actual driver callbacks. The delay tool reports a 42.666667
ms median and p95. Callback timing is simulated: this is not live HAL delay.

## Installation

Use the app's explicit Install button or follow
[the device setup guide](../docs/virtual-device.md). Administrator access and
a macOS restart are required. Scripts do not restart audio services, change
default devices, install BlackHole, or reboot automatically. This local driver
is ad-hoc signed, not notarized for distribution. System loading and live
recording on Tahoe remain pending until installation is tested.
