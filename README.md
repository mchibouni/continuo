# karmic

A band that follows the chords you play, in the spirit of Korg's KARMA. Play chords on a
MIDI keyboard. karmic names each chord, and its parts play patterns over it: bass, keys, an
arpeggio and a pad. Each part sends MIDI on its own channel to whatever synths you point it
at. karmic makes no sound itself.

macOS 14 or later, Swift 5.10 or later.

```
swift build -c release
.build/release/karmic                  # run it; the first chord starts the band
karmic --gm --config examples/general-midi.json   # also hear it on macOS's built-in GM synth
karmic ctl scene jazz                  # steer it while it runs
karmic render Dm9 G13 Cmaj9 A7alt --scene bossa --out demo.mid   # rehearse it silently
```

## How it plays

- **Styles** are a bar of sixteenths written as text (`Sources/KarmicCore/Styles.swift`). A
  digit starts a note and says how strong its step is, `-` holds it, and a role letter says
  what the note is: root, fifth, approach note, ghost, the whole voicing, its top notes, and
  so on. `karmic styles` lists them all.
- **Density** drops the weakest steps first, so turning it down thins a groove the way a
  player would. **Complexity** brings in richer notes: tensions in the voicings, and approach
  notes and thirds in the bass.
- **Keys** play rootless voicings (3rd and 7th first, then tensions) and move as little as
  possible from the last chord. Dm9 → G13 → Cmaj9 comes out as C F G E → B F A E → B D A E.
- **Chord changes:** a chord is named once its notes have all arrived, 15 ms after the last
  one. A hit that falls due while a chord is still arriving waits for it, up to 60 ms. A
  chord that arrives after a hit has started re-voices whatever is still sounding and keeps
  the notes both chords share. Playing a change a hair before the beat gives a clean change
  on the beat, as with an arranger keyboard.
- **Scenes** switch styles and settings in one go. A scene starts again from the config, so
  anything changed with `ctl set` lasts until the next scene.

## Commands

```
karmic ctl start | stop | panic | status
karmic ctl tempo 112 | swing 62 | feel 8
karmic ctl scene [name or number]
karmic ctl chord Dm9                   # as if you had played it
karmic ctl set bass.density 0.4        # any part setting from the config
karmic ctl mute arp | unmute arp | toggle pad
karmic render Am7 D9 Gmaj7 --audio a.m4a --json a.json   # render audio (built-in GM synth) and note data
karmic chord D2 F2 A2 C3 E3            # name the chord in some notes (C3 = 60)
karmic ports                           # MIDI sources and destinations
karmic init                            # write the standard config to edit
```

`ctl` sends one line over UDP to 127.0.0.1:47130, so anything that can send a UDP packet can
steer the band: a controller script, Hammerspoon, a shell alias.

## Config

`karmic init` writes the standard config to `~/.config/karmic/config.json`:

- `inputs`: the MIDI sources whose notes make the chord. Each has an optional channel and an
  optional `zone` (the range of notes that count), so the left hand can play the chords while
  the right hand plays freely.
- `outputs`: karmic's own virtual port (`"port": "virtual"`, it shows up as "karmic") or any
  destination by name (see `karmic ports`)
- `parts`: name, kind (`bass`, `comp` or `arp`), style, output, channel, range, density,
  complexity, velocity, voices, swing, loop length, variation…
- `program`: a part setting (1-128) sent as a program change when the band starts and when
  a scene changes it. `examples/general-midi.json` uses it to pick General MIDI sounds per scene.
- `scenes`: per-part overrides, plus tempo and swing
- `clockOut`: outputs that get MIDI clock and start/stop, so a drum machine follows the band

Some hosts enable every new MIDI input automatically. When karmic's port appears, make sure
each instrument listens only to its own part's channel.

## Testing without sound

`karmic render` plays a progression into the engine on a simulated clock. It prints every
part bar by bar, checks the result and can write a MIDI file. The checks are that every note
ends, mono parts stay mono, and notes stay in range and in the chord's palette. `--late 30`
plays the chords 30 ms behind the beat, to hear how the band catches up. `swift test` runs
every style early, on time and late through slash chords and altered dominants.

## License

MIT
