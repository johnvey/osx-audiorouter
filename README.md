# Announcer

A tiny native macOS menu bar app that routes specific apps to specific audio **output** devices — a minimal subset of [SoundSource](https://rogueamoeba.com/soundsource/). No drivers, no kernel extensions: it uses the CoreAudio process-tap API built into macOS 14.4+.

## Usage

```sh
./build.sh
cp -R build/Announcer.app /Applications/
open /Applications/Announcer.app
```

Click the speaker icon in the menu bar, pick an app, pick an output device. Pick **System Default** to stop routing that app. Each app's submenu also has a **volume slider** that adjusts that app alone — it works whether or not the app is routed to another device. Enable **Launch at Login** to make it persistent.

The first time a route activates, macOS asks for **System Audio Recording** permission (Settings → Privacy & Security). This is required — process taps are technically an audio-capture facility, even though Announcer only re-renders the audio and never records it.

## How it works

For each routed app that has a live audio presence, Announcer:

1. Creates a CoreAudio **process tap** (`AudioHardwareCreateProcessTap`) over all of the app's audio processes, with `mutedWhenTapped` behavior — so the app's normal output is silenced while the tap is read.
2. Creates a **private aggregate device** wrapping the chosen output device, with the tap attached (drift-compensated).
3. Runs a realtime IO proc on the aggregate that copies the tap's stereo audio into the output device's buffers, applying the app's volume as a per-sample gain.

Per-app volume without re-routing works the same way: the tap re-renders to the current system default device (and follows default-device changes). Volume changes on a live route just update the gain — no tap rebuild, no glitch.

Everything is event-driven via CoreAudio property listeners (device plug/unplug, audio processes appearing/exiting, default-device changes) — no polling, and zero audio I/O when no routes are active. Rules persist in `~/Library/Application Support/Announcer/rules.json` keyed by bundle ID, and re-apply automatically when apps relaunch or devices reappear.

## Limitations

- macOS 14.4 or later.
- Output routing and per-app volume only (no input, no MIDI, no EQ).
- Per-app volume is a linear gain applied to the app's audio; it is independent of (and multiplies with) the device's hardware volume.
- Apps are matched by bundle ID, including helper processes with the app's bundle ID as a prefix (covers Chrome/Electron helpers). Safari's audio comes from the shared `com.apple.WebKit.GPU` process, which is special-cased — but routing Safari may also route other WebKit-based apps' audio.
- Routed audio is a stereo mixdown (surround sources are downmixed).
- Quitting Announcer removes all taps, so apps immediately revert to their normal output.

## Development

```sh
swift build          # debug build
./build.sh           # release build + .app bundle (ad-hoc signed)
```

Sources are plain AppKit + CoreAudio, one executable target, no dependencies.
