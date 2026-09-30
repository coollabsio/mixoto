# Use the Stream Mix virtual input

No OBS setup is required. Mixoto publishes **Mixoto Stream Mix** as a
stereo input. Select it in a recorder, call application, or other audio-input
client. Each source's Stream gain and mute control its contribution; Monitor
controls do not change this input.

## Install

1. Build the app: `rtk proxy sh scripts/build-app.sh`.
2. Open it: `rtk proxy open artifacts/Mixoto.app`.
3. Click **Install…** (to update: **Mixoto > Reinstall Virtual Device…**). macOS asks for administrator
   access. The app does not collect or save your password.
4. The installer restarts Core Audio (`killall coreaudiod`; launchd starts it
   again) so macOS loads the driver now. System audio stops for a few
   seconds and apps that use audio can lose their device for a moment.
5. The device list updates by itself. If the device is still missing,
   restart macOS. The status must say
   **Mixoto Stream Mix — available**.

## Rename

Type a new name in the Stream Mix row and press Return. The driver stores it
and announces the change; it stays after a Core Audio restart or reboot.
Apps find the device by its fixed UID `local.mixoto.stream-mix`, so OBS and
other saved setups keep working; some apps show the new name only after they
refresh their device list. Driver 0.3.0 or later is required
(**Mixoto > Reinstall Virtual Device…**).

The install location is
`/Library/Audio/Plug-Ins/HAL/MixotoAudio.driver`.
Installation does not select a default audio input or output.

Terminal alternative, after building:

```sh
rtk proxy sudo /bin/sh scripts/install-driver.sh "$PWD/artifacts/MixotoAudio.driver"
```

## Create the combined mix

1. Add source channels and assign the applications or one microphone.
2. Set Stream gains low. Unmute only the channels to include in the mix. A
   Stream-muted channel contributes silence. There is no extra source channel
   to add: the virtual device is the output of the combined Stream graph.
3. Set Monitor to **Off — Stream Mix only**, or choose low-volume headphones.
4. Start source playback, then assign it to a channel (the mixer starts automatically). Grant capture permissions if
   macOS asks.
5. In your input application, select **Mixoto Stream Mix**. Grant that app
   microphone access if needed. Do not also capture the source applications.
6. Record both source channels. Verify that Stream mute removes a source,
   while Monitor mute does not change the recorded mix.

Only Mixoto should write to the virtual device's output. Another writer can
add audio to its input and bypass per-channel controls. Do not use it as the
system sound output. Do not assign an audio router or its receiving app as a
source: that can create feedback.

If Mixoto stops, the input becomes silent after the buffered tail. The
driver remains installed; closing the app does not remove the device.

## Remove the device

Stop the mixer and your input application, then run:

```sh
rtk proxy sudo /bin/sh scripts/install-driver.sh --uninstall
```

The script restarts Core Audio to unload it. It only removes a bundle with Mixoto's
identifier at the fixed Mixoto path. It does not remove other audio drivers.

## Verification limits

Driver builds, local CFPlugIn loading, PCM loopback, and sanitizer tests are
automated. **Administrator installation, macOS audio-server loading, and live
input recordings are not verified yet.** If the device does not appear after
the Core Audio restart, keep the error/logs and do not treat a successful build as proof that
the device loaded.

The configured driver buffer shift is 2,048 frames at 48 kHz, or about 42.7 ms.
That is not total audio delay. Use the real reference/return recording method
in [README.md](../README.md) to measure the complete path. Helper-process audio,
automatic reconnect, limiting, and long-session behavior remain unfinished.
