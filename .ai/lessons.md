# Lessons

- User correction, 2026-09-30: Stream Mix means one combined virtual audio
  device, not an OBS-specific route. Build and label the device as
  **Mixoto Stream Mix**. Any audio-input client can read it. Do not make OBS
  or a separately installed BlackHole device a requirement for this route.
- Distinguish driver implementation, installation, system discovery, and live
  audio verification. A built driver is not an installed or verified device.
- User correction, 2026-09-30: A full macOS restart is not an inherent
  requirement of a virtual audio device. Explain that the current installer
  does not reload Core Audio. Distinguish conservative restart instructions
  from verified loading behavior. Test an audio-service reload before claiming
  it works, warn that it interrupts system audio, and do not run it without
  explicit user action. Do not guess how Elgato loads its software.
- User correction, 2026-09-30: The installer must restart Core Audio itself,
  not tell the user to restart macOS. Install/uninstall run
  `killall coreaudiod` after the explicit, administrator-authorized install
  action. Show the audio interruption before the password prompt, then
  re-list devices and report whether the driver really loaded.
- 2026-09-30: macOS 26 sizes SwiftUI pop-up Pickers to their content and
  centers them in any larger frame; `.frame(maxWidth:)` does not stretch them.
  Use `.buttonSizing(.flexible)` (macOS 26+) with a fixed frame. Verify layout
  by walking the NSHostingView subviews and printing NSPopUpButton/NSTextField
  frames; offscreen image renders do not draw these controls.

- User correction, 2026-09-30: Driver installation/reinstallation interrupts
  audio. Clear both displayed capture/drop counts with the stopped graph and
  suspend counter polling while installation is busy. Reset the UI and the
  underlying counter lifetime together; do not show installation-era drops
  as counts from the new session.

- User correction, 2026-09-30: Do not repeat the Mixoto app title or a general
  description inside the mixer. Keep the content focused on audio controls;
  retain the start/stop control when removing decorative headers.

- User correction, 2026-09-30: Capture/drop counts are diagnostic details.
  Hide them behind a debug icon with an on-demand popover. Keep actionable
  errors and installation messages visible outside that popover.

- User correction, 2026-09-30: The debug control must look like a standalone
  icon, without glass, a border, or a button background. Keep a plain Button
  internally for keyboard/accessibility and native popover behavior.

- User correction, 2026-09-30: New channels must start at 100% for both
  Monitor and Stream Mix. Set defaults in Channel; preserve saved volumes.

- User correction, 2026-09-30: Maxio already uses an M. Give Mixoto a
  distinct audio-merging symbol, not another purple M. Use pixel-grid SVG
  for the requested asset; save it in the application project directory.

- When copying a visual detail from a reference (shadow side, offset, color), measure it from the reference pixels (e.g. `magick ... txt:-` row/column scan) instead of guessing from a small preview. Guessed Jean's icon shadow as down-left; it is down-right.

- User correction, 2026-09-30: Keep the README brief. Do not include RTK commands in it. Prefix shell tool commands with `rtk`, as required by the local instructions.

- Do not put the local `rtk` wrapper in repository scripts or README commands.
  CI runners and other developers do not have it. Use plain commands in files;
  use `rtk` only in your own shell calls.

- User version correction, 2026-09-30: The next app release is 0.0.2, not
  0.2.0. Use the requested release version for both app version fields.
  Check repository variable/secret names before assuming how the user stored
  update keys; the public key can safely be supplied from either location.

- User correction, 2026-09-30: Use only the supplied screenshot for the README.
  Do not add more screenshots or request more images when one is sufficient.

- User correction, 2026-09-30: The menu bar icon must use the same three-fader
  design as the app icon, not a generic waveform. Use a monochrome template
  without the app tile/background so macOS can adapt it to the menu bar.

- User correction, 2026-09-30: A feature was "missing" because the running
  `artifacts/Mixoto.app` was an old bundle; only `swift build` had run. After
  UI/app changes, run `sh scripts/build-app.sh`, confirm the binary timestamp
  is newer than the sources, and say whether the running app must restart.

- User correction, 2026-09-30: Do not use the long dash (—) in UI text; use a
  plain hyphen with spaces (" - "). For unavailable saved sources, show the
  saved name, for example "App: Helium - not available", not a generic label.

- User regression, 2026-11-02: Nonblocking output locks silently dropped live audio blocks after removing bus serialization. Preserve lossless serialized delivery; remove control-side Core Audio calls from shared lock scopes. Unit tests do not establish live audio quality.

- 2026-11-03: In zsh, `log` is a shell builtin. Use `/usr/bin/log show` to
  read unified logs; the builtin prints nothing and looks like "no logs".
  Logger `info` lines are not kept on disk; use `notice` or `error` for
  diagnostics that must survive until the user reports a problem.
- 2026-11-03: "App plays output" (kAudioProcessPropertyIsRunningOutput) does
  not mean the app makes sound. Klack keeps output open and silent between
  key presses. Do not repair captures on that signal; log it only.

- 2026-11-05: Rebuilding a process tap while the tapped app starts or stops
  its output hung coreaudiod (AudioDeviceDestroyIOProcID never returned; only
  `sudo killall coreaudiod` recovers). Never rebuild taps on raw Core Audio
  change events; wait until the app's audio is stable. Test tap-rebuild
  changes for hangs (sample the process) before handing a build to the user.

- 2026-11-09: Two main-thread deadlocks hung Mixoto when AirPods connected.
  (1) OutputBus.sync called player.play() while holding the bus lock;
  play() waits on the engine's I/O unit queue -> Core Audio -> a tap I/O
  cycle that waits in feed() for the same lock. (2) The
  AVAudioEngineConfigurationChange observer used `queue: .main`, which makes
  the posting engine queue wait for main while main waited for that queue in
  an engine deinit. Rules: no AVAudioEngine/player/Core Audio call inside a
  lock that audio callbacks take; observe engine notifications with
  `queue: nil` and hop to main. Reproduce device-change hangs by switching
  the default output device in a loop and sampling the process.
  Run `sh scripts/stress-device-switch.sh 20 <other output ID>` before a
  release that touches audio threading; it failed on v0.0.10 and passes now.

- 2026-11-12: AirPods dips/"thin" sound with Mixoto after Cmd-Tab to
  Moonlight. I first blamed AirPods features, then Mixoto's queue sizes; the
  user corrected both ("no problem without Mixoto"; fixes changed nothing).
  Real cause: Game Mode makes AirPods change their jitter buffer by playing
  ~10% faster/slower for ~1 s (bluetoothd "audio delivery speed ...
  multiplier"). Apps follow; taps on their own clock did not. Fix: clock tap
  aggregates by the default output (main subdevice). Rules: when the user says
  "only with Mixoto", compare system logs (bluetoothd, coreaudiod,
  gamepolicyd) with and without Mixoto before changing code. After two failed
  fixes on one premise, test the premise. Count events per second (empty
  player, drops, tap frames/s) instead of guessing from symptoms.
- 2026-11-12: scripts/stress-device-switch.sh now fails on v0.0.12, HEAD and
  the fix alike (EXC_BAD_ACCESS in AVAudioIOUnit::IOUnitPropertyListener).
  Run the stress test on the old build too before blaming a new change.
