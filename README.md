# NoDuck

Stops macOS from turning your music and videos down while you're on a FaceTime call. It works for other call apps that
do the same (Zoom, Teams, WhatsApp…) too.

As soon as a FaceTime call starts, macOS lowers every other app by roughly 15–20 dB ("ducking"). There is no setting to
turn that off. NoDuck is a small menu bar app that keeps other apps at full volume during calls and does nothing the
rest of the time.

## Install

You need macOS 14.2 or later (Apple Silicon or Intel; the technique has been used on 14.4 and later) and the Xcode
Command Line Tools 15.1 or later. Full Xcode is not needed:

```sh
xcode-select --install      # once, if you don't have them yet
cd NoDuck
./build.sh install
```

This builds `NoDuck.app` and copies it to `/Applications`. It also adds a login agent, so NoDuck starts now and at
every login. When macOS asks, allow **System Audio Recording** for NoDuck. A bird appears in the menu bar.

Other commands:

| Command | What it does |
| --- | --- |
| `./build.sh` | build `build/NoDuck.app` only |
| `./build.sh run` | build and start it once, without installing |
| `./build.sh uninstall` | remove the app, the login agent, its settings and its permission |

## Use

| Menu bar icon | Meaning |
| --- | --- |
| bird (outline) | waiting for a call |
| bird (filled) | a call is running, other apps stay at full volume |
| speaker with a slash | switched off, or the permission is missing |
| warning triangle | something went wrong (the menu says what) |

The menu has:

- **Keep Other Apps Loud During Calls**: switches NoDuck on or off.
- **Only for FaceTime Calls**: ignores every other app that uses the microphone.
- **Allow System Audio Recording…**: appears only while the permission is missing.
- **Open Log**, **Quit**.

## How it works

1. **Spotting a call.** A call is any app using a microphone, or one of FaceTime's processes (`avconferenced`,
   `callservicesd`, FaceTime.app) using the microphone or playing sound. That means a ringing FaceTime call counts
   too. Siri and dictation don't count.
2. **Capturing other apps.** During the call, NoDuck creates a Core Audio *process tap* on your output device. The tap
   mutes the apps it covers and hands their sound to NoDuck. It covers every app except:
   - every process of an app using the microphone (all of Chrome during a Meet call, for example)
   - all of FaceTime's processes
   - VoiceOver
   - NoDuck itself
3. **Playing them back.** NoDuck plays that sound back to the same device. While it does, it holds a duck request of
   its own at an inaudible −0.01 dB. The audio server never ducks a process that holds its own duck request. So the
   call can duck "other apps" as much as it likes: the originals are muted anyway, and NoDuck's replay is exempt.
4. **Cleaning up.** About 4 seconds after the call ends, the tap is removed and the apps play directly again. If
   NoDuck quits or crashes, macOS does the same automatically.
5. **Stepping aside when it can't help.** Sometimes the tap delivers silence for 5 seconds while other apps are
   playing. That usually means the permission isn't really granted, and the tap would keep those apps muted. Other
   times macOS refuses the duck request. In either case NoDuck stops, shows the problem in its menu, and tries again
   30 seconds later.

```
Without NoDuck:  Music ──────────────────────► speakers   (ducked −15…20 dB by the call)
With NoDuck:     Music ──► tap ──► NoDuck ───► speakers   (NoDuck is exempt, so full volume)
                 FaceTime ───────────────────► speakers   (untouched)
```

## Trade-offs

- **Delay.** During calls, other apps' sound runs through NoDuck. That adds about 0.1 s of delay, so video lip-sync
  can be slightly off. Spatial Audio is folded down to the device's channels. When there's no call, nothing changes.
- **Short gaps.** Other apps go silent for about 0.1 s when a call starts, when it ends, and when you switch output
  devices.
- **Recording indicator.** During calls, macOS shows its purple system audio recording indicator for NoDuck.
- **The first second.** FaceTime ducks other apps slightly before its call audio starts, so the first second of a call
  may still be quiet.
- **Echo.** Without ducking, your music stays loud. On the Mac's speakers, the microphone picks it up and the other
  person may hear it. Headphones avoid that.
- **One device.** Only the current default output is protected. If FaceTime uses a different output than the rest
  of the Mac, macOS doesn't duck the other apps in the first place.
- **Screen sharing.** If you share your whole screen with sound, the other side may hear other apps twice. Share a
  window instead.
- **Always-on microphone apps.** Meeting recorders, noise filters and similar tools keep NoDuck active the whole time
  they run. The menu shows which app it thinks is the call; add that app to `IgnoredApps` (see Settings).
- **One unducker at a time.** NoDuck stays idle while ShutTheDuckOff or Unduck Pro is running. They do the same job,
  and two such apps would tap each other's sound.
- **Undocumented behaviour.** NoDuck relies on behaviour Apple doesn't document. `AudioDeviceDuck` is an exported
  CoreAudio function that WebKit and Chromium also call. The permission prompt uses the private TCC framework, because
  there's no public API for it. A future macOS update could break either one. See [Alternatives](#alternatives).

## Settings

```sh
# An app that uses the microphone but isn't a call (bundle ID prefix or process name):
defaults write local.noduck IgnoredApps -array "com.example.Recorder" "SomeTool"

# Protect a specific output instead of the default one (UIDs are listed by --diagnose):
defaults write local.noduck Device "BuiltInSpeakerDevice"

# Only if NoDuck says it can't check the permission, but you have granted it:
defaults write local.noduck AssumePermission -bool true
```

NoDuck reads these every second, so you don't need to restart it.

## Troubleshooting

- **Log:** menu > Open Log, or `tail -f ~/Library/Logs/NoDuck.log`, or
  `log stream --predicate 'subsystem == "local.noduck"'`.
- **Diagnostics:** `/Applications/NoDuck.app/Contents/MacOS/NoDuck --diagnose`. Run it during a call with music
  playing. It lists output devices, every audio process, what's using the microphone, and which device each process
  plays to.
- **Other apps went silent during a call:** quit NoDuck from its menu and everything goes back to normal at once. Then
  check the log.
- **The permission:** System Settings > Privacy & Security > Screen & System Audio Recording > *System Audio Recording
  Only* > NoDuck. Each rebuild gets a new ad-hoc signature, which macOS treats as a new app. That's why
  `./build.sh install` and `./build.sh run` reset the old entry, so you get a fresh prompt.
- **Still ducked:** look in the log for a line like `duck request 0.999 on External Headphones: 0`. A status other than
  0, or no such line, means your macOS version behaves differently. In that case use one of the alternatives below.

## Alternatives

- [Duckproof](https://github.com/IV2FI/duckproof) is free, open source and notarized. It takes the other route: it
  gives FaceTime its own virtual output device, which macOS ducks instead of your speakers. It needs an audio driver
  and a one-time FaceTime setting, but it doesn't touch your music at all.
- [ShutTheDuckOff](https://github.com/anegoda1995/ShutTheDuckOff) uses the same technique as NoDuck. NoDuck follows its
  approach. Don't run the two at the same time.

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)), the same as ShutTheDuckOff, whose approach NoDuck follows. NoDuck is not
affiliated with Apple. FaceTime is a trademark of Apple Inc.
