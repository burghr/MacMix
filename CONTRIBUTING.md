# Contributing

MacMixer is a small, focused personal fork of
[Background Music](https://github.com/kyleneideck/BackgroundMusic): a menu bar
per-app volume mixer and nothing more. See the *"Why a fork?"* section of the
[README](/README.md) for what it deliberately keeps, drops, and adds.

### Where to contribute

- **The general audio utility** (auto-pause music, music-player integrations,
  recording, AppleScript, system-sound routing, the audio driver itself) lives
  upstream. Bug reports and PRs for that belong in
  [kyleneideck/BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic).
- **MacMixer-specific things** (the SwiftUI mixer UI, per-app boost, hide-apps,
  output-device sample-rate handling) — issues and PRs here are welcome.

### Working on MacMixer

Everything MacMixer-specific is under `BGMApp/BGMApp/MacMixer/`. The
[README's *Development & maintenance* section](/README.md#development--maintenance)
covers the architecture (the `MixerEngine` seam over BGM's audio core), the
build command, and how to redeploy after a change. The original
[DEVELOPING.md](/DEVELOPING.md) still applies to the inherited driver/engine.

### License

MacMixer is GPLv2 (or later), inherited from Background Music. Keep the existing
license headers, and add a copyright notice with your name to any source files
you change substantially.
