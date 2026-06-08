# MacMixer

A menu bar **volume mixer** for macOS: a master volume slider, an output-device
picker, and a per-app volume slider for every running app — in a clean,
native SwiftUI popover.

> **MacMixer is a fork of [Background Music](https://github.com/kyleneideck/BackgroundMusic)
> by Kyle Neideck and contributors.** It reuses Background Music's audio engine
> and virtual audio driver wholesale, and replaces the original AppKit menu UI
> with a SwiftUI menu bar popover. All the hard audio work — the virtual device,
> per-app stream capture, and glitch-free playthrough — is theirs. Huge thanks
> to that project.

## Why a fork?

Background Music is a powerful, general-purpose audio utility — it auto-pauses
your music player when other audio starts, integrates with Spotify/Music/VLC/etc.,
exposes an AppleScript interface, routes system sounds separately, and can record
system audio. That's a lot of surface area, and its UI is a dense AppKit status-bar
menu built around all of it.

MacMixer wants to do **one thing well: be a simple per-app volume mixer that lives
in the menu bar.** So this fork keeps the part of Background Music that's genuinely
hard and valuable, and drops everything else:

**Kept (unchanged):** the virtual audio driver and the audio engine — capturing
each app's audio, applying per-app gain, and playing it back glitch-free. This is
the difficult code, and there's no reason to reinvent it.

**Replaced:** the AppKit status-bar menu → a clean, native **SwiftUI popover**:
an output-device picker at the top, a master slider, and one slider per running
app. That's the whole interface.

**Dropped (not needed for a volume mixer):**
- **Auto-pause music** and all the music-player integrations (Spotify, Music,
  iTunes, VLC, Swinsian, …)
- The **AppleScript** scripting interface
- The **About / Preferences** panels and the separate system-sounds slider

**Added on top:** a per-app **boost** control with a clear indicator above 100%,
the ability to **hide apps** you never adjust (with sensible defaults like Finder
and Terminal pre-hidden), and **automatic sample-rate re-sync** so audio keeps
working when a Bluetooth headset (e.g. AirPods) switches into call mode.

The result is a smaller, more focused app: open the menu, see your apps, drag a
slider. No configuration, no music-player babysitting, no clutter.

## How it works

macOS has no public API for per-application output volume. Background Music
solves this with a virtual audio device (a HAL plugin) that becomes the system
default output, captures each app's audio (tagged by process), applies per-app
gain, and plays the mix back through your real output device. MacMixer keeps
that engine and driver unchanged and talks to it through a thin Objective-C++
bridge (`MixerEngine`), driving everything from a SwiftUI front end.

```
Your apps ─audio─▶ Background Music Device (virtual, captures + per-app gain)
                          │
                          ▼
                   MacMixer.app (playthrough + SwiftUI mixer UI)
                          │
                          ▼
                   Your real output device
```

## Layout of the fork

| Path | Role |
|---|---|
| `BGMDriver/` | The virtual audio driver — **unchanged** from Background Music |
| `BGMApp/BGMApp/MacMixer/` | New MacMixer SwiftUI front end + the `MixerEngine` bridge |
| `BGMApp/BGMApp/BGM*` | Background Music's audio core (device manager, playthrough, …) — kept; the old AppKit UI classes are left in but unused |
| `build_and_install.sh` / `uninstall.sh` | Background Music's installer, re-pointed at `MacMixer.app` |

The new front end:

- `MixerEngine.{h,mm}` — Swift-facing facade over `BGMAudioDeviceManager` /
  `BGMBackgroundMusicDevice`: start/stop, output devices, master volume,
  per-app volume.
- `MacMixerApp.swift`, `AppDelegate.swift` — menu bar status item + transient
  `NSPopover` (LSUIElement, no dock icon).
- `MixerModel.swift` — `ObservableObject` bridging the engine to SwiftUI.
- `PopupView.swift` — output picker, master slider, per-app sliders.

## Build & install

> Installs a system audio driver, so it needs your admin password and (on
> recent macOS) approval in **System Settings → Privacy & Security**. It also
> requests **Microphone** permission — the engine routes audio through a virtual
> input device.

```
bash build_and_install.sh
```

This builds the driver, the XPC helper, and `MacMixer.app`, installs them, and
restarts `coreaudiod`. After it finishes, grant Microphone permission to
MacMixer when prompted (or in System Settings) and relaunch it.

**If MacMixer says it can't find the audio device** (or there's no "Background
Music" device in Sound settings), the installer's `coreaudiod` restart didn't
take — common on recent macOS. Restart it manually, then relaunch MacMixer:

```
sudo killall coreaudiod
```

## Uninstall

```
bash uninstall.sh
```

## Notes

- **Internal bundle identifiers are still `com.bearisdriving.BGM.*`.** The
  driver and XPC helper trust each other by these IDs, so the fork keeps them to
  avoid breaking the handshake. Only the user-facing app (name, menu bar title)
  is rebranded to MacMixer. This means MacMixer and the real Background Music app
  can't be installed at the same time.
- Per-app sliders list all regular running apps; volume defaults to 100%.

## Development & maintenance

Everything MacMixer-specific lives in **`BGMApp/BGMApp/MacMixer/`**. The rest of
the tree is Background Music, mostly untouched.

### The seam

The SwiftUI UI never touches C++/CoreAudio directly. It goes through one
Objective-C++ facade:

```
SwiftUI (MixerModel)  →  MixerEngine (ObjC++)  →  BGMAudioDeviceManager / BGMBackgroundMusicDevice  →  BGMDriver
```

- **`MixerEngine.{h,mm}`** — the only file that calls BGM's C++. Add new audio
  capabilities here and expose them as plain ObjC methods so Swift can call them.
  - per-app volume → `BGMBackgroundMusicDevice::SetAppVolume / GetAppVolumes`
    (the `kAudioDeviceCustomPropertyAppVolumes` `'apvs'` property, range 0–100)
  - master volume/mute → `Get/SetVolumeControlScalarValue` / `…MuteControlValue`
    on the BGM device (`kScope` = output, `kMasterChannel` from `BGM_Types.h`)
  - output devices → `CAHALAudioSystemObject`
  - startup → create `BGMAudioDeviceManager`, pick a real output device,
    `setBGMDeviceAsOSDefault`, then create **`BGMXPCListener`** (required — without
    it the driver's `StartIO` never reaches us and playthrough won't start)
  - it also installs a `kAudioDevicePropertyNominalSampleRate` listener on the
    output device and calls `[manager resyncSampleRate]` on change (fixes Bluetooth
    call-mode slow-mo)
  - pin Swift names with `NS_SWIFT_NAME(...)` when a selector imports ambiguously
- **`MixerModel.swift`** — `@MainActor ObservableObject`. Lists running apps,
  polls every 2 s. Note: the per-app slider is the source of truth — `refreshApps`
  preserves on-screen values and only queries the engine for newly-seen apps.
- **`PopupView.swift` / `AppDelegate.swift` / `MacMixerApp.swift`** — the menu bar
  status item, transient `NSPopover`, and the popover layout.
- Two small edits in BGM core: `-[BGMAudioDeviceManager resyncSampleRate]` (+ its
  header decl).

### Build

```
xcodebuild -project BGMApp/BGMApp.xcodeproj -scheme "Background Music" \
  -configuration Release -derivedDataPath .build-rel \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="-" build
```

The scheme is still named **"Background Music"**; the product is **`MacMixer.app`**.

### Redeploy after a code change (no full reinstall)

The driver and XPC helper are already installed, so you only need to replace the
app — no `sudo`, no `coreaudiod` restart:

```
NEW=.build-rel/Build/Products/Release/MacMixer.app
codesign --force --deep --sign - "$NEW"
killall MacMixer 2>/dev/null
rm -rf /Applications/MacMixer.app && cp -R "$NEW" /Applications/MacMixer.app
open -a MacMixer
```

(Re-running `build_and_install.sh` is only needed when you change the **driver** or
**XPC helper**.)

### Xcode project gotchas (in `BGMApp.xcodeproj`)

The app target was an Objective-C XIB app; making it a SwiftUI app required:

- `main.m` + `MainMenu.xib` removed from the target; `NSMainNibFile` removed from
  `Info.plist`. (BGM's other ObjC UI classes are left in the target, unused.)
- App-target build settings added to all 3 configs (Debug/Release/DebugOpt):
  `SWIFT_VERSION=5.0`, `SWIFT_OBJC_BRIDGING_HEADER` (→ `MacMixer-Bridging-Header.h`),
  `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES`, `PRODUCT_NAME=MacMixer`,
  `MACOSX_DEPLOYMENT_TARGET=12.0` (SwiftUI App lifecycle needs 11; `.foregroundStyle`
  needs 12), and `GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS=NO` (the 12.0 bump makes BGM's
  `kAudioObjectPropertyElementMaster` trip `-Werror`).
- MacMixer's file/build references in the pbxproj use IDs prefixed `FACADE…` so
  they're easy to find.

### Useful checks

```
pgrep -lf MacMixer                                   # is it running?
system_profiler SPAudioDataType | grep -i background # is the driver loaded?
# which device is the system default output (should be "Background Music"):
system_profiler SPAudioDataType | awk '/^ {8}[A-Za-z].*:$/{n=$0} /Default Output Device: Yes/{print n}'
log show --last 10m --predicate 'process == "MacMixer"' --style compact
```

### Known open items

- Startup picks whatever the current system default output is; it doesn't yet
  remember the user's chosen device.
- No login auto-start LaunchAgent.
- The per-app list shows all regular running apps, not only ones playing audio.

## License

GPLv2 (or later), inherited from Background Music. See `LICENSE`. Background
Music is Copyright © Kyle Neideck and contributors; MacMixer's modifications are
likewise GPLv2.
