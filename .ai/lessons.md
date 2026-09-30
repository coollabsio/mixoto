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
