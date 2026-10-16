# Continuo

A band that follows the chords you play. Play chords on a MIDI keyboard. Continuo names each
chord, and its parts play patterns over it: bass, keys, an arpeggio and a pad. Each part sends
MIDI on its own channel to whatever synths you point it at. Continuo makes no sound itself.

The name comes from the basso continuo of baroque music: the keyboard and bass players who
made up the chords on the spot from a bass line and a few figures.

macOS 14 or later, Swift 5.10 or later.

```
swift build -c release
.build/release/continuo                  # run it; the first chord starts the band
continuo --gm --config examples/general-midi.json   # also hear it on macOS's built-in GM synth
continuo ctl scene jazz                  # steer it while it runs
continuo render Dm9 G13 Cmaj9 A7alt --scene bossa --out demo.mid   # rehearse it silently
```

## How it plays

- **Styles** are a bar of sixteenths written as text (`Sources/ContinuoCore/Styles.swift`). A
  digit starts a note and says how strong its step is, `-` holds it, and a role letter says
  what the note is: root, fifth, approach note, ghost, the whole voicing, its top notes, and
  so on. `continuo styles` lists them all.
- **Density** drops the weakest steps first, so turning it down thins a groove the way a
  player would. **Complexity** brings in richer notes: tensions in the voicings, and approach
  notes and thirds in the bass.
- **Keys** play rootless voicings (3rd and 7th first, then tensions) and move as little as
  possible from the last chord. Dm9 → G13 → Cmaj9 comes out as C F G E → B F A E → B D A E.
- **Players' voicings:** with a voicing bank, keys parts play the shapes pianists actually
  used instead. `continuo mine` reads MIDI files of real playing, names every chord struck,
  sets the left hand's bass aside and keeps the rest as a shape, tagged with the style you
  give it. A part then plays the shape that moves least from its last voicing and sits well
  in its range, preferring shapes players used often. From a bank of jazz piano, Dm9 → G13 →
  Cmaj9 comes out as C E F A → B E F A → B D E G. Chords the bank has never seen fall back to
  the rules above.
- **Players' phrases:** with a phrase bank, a part plays phrases real players played instead
  of its style's one-bar pattern: a comping figure, a bass line, an ostinato, a few bars long,
  with the player's timing and dynamics. Every note keeps its job in the chord (3rd, 7th,
  9th, a chromatic step into the next note) and moves to that job in the chord you're
  holding, as near as it can to where the player had it, so the phrase keeps its contour.
  Parts that play phrases follow one groove together: bass, keys and lines come from the
  same song and the same take, so they interlock the way they were written. The band moves
  through a section's takes and stays in it until you change it (`continuo ctl section
  chorus`), or moves to another groove (`continuo ctl next`).
- **Drums:** a `drums` part plays drummers' grooves from the phrase bank as recorded, on
  channel 10, and a fill in the last bar before the band's next take, as an arranger does. It
  plays its band song's own drums when that song has them. Drums have no pattern of their own.
- **One key is enough:** a single bass note, or a root and its fifth, plays as a major chord,
  as on an arranger keyboard.
- **Chord changes:** a chord is named once its notes have all arrived, 15 ms after the last
  one. A hit that falls due while a chord is still arriving waits for it, up to 60 ms. A
  chord that arrives after a hit has started re-voices whatever is still sounding and keeps
  the notes both chords share. Playing a change a hair before the beat gives a clean change
  on the beat, as with an arranger keyboard.
- **Scenes** switch styles and settings in one go. A scene starts again from the config, so
  anything changed with `ctl set` lasts until the next scene.

## Commands

```
continuo ctl start | stop | panic | status
continuo ctl tempo 112 | swing 62 | feel 8
continuo ctl scene [name or number]
continuo ctl chord Dm9                   # as if you had played it
continuo ctl set bass.density 0.4        # any part setting from the config
continuo ctl mute arp | unmute arp | toggle pad
continuo render Am7 D9 Gmaj7 --audio a.m4a --json a.json   # render audio (built-in GM synth) and note data
continuo render Am7 D9 Gmaj7 --scene funk --sounds examples/arturia-sounds.json --audio a.m4a   # through your plugins
continuo sounds                          # the instrument plugins a render can use
continuo chord D2 F2 A2 C3 E3            # name the chord in some notes (C3 = 60)
continuo mine --tag jazz ~/MIDI/jazz --tag soul ~/MIDI/soul   # build the voicing bank
continuo voicings Dm9 G13 --tag jazz     # what the bank plays for some chords
continuo phrases                         # the players' phrases it learned, by style
continuo ctl section chorus              # phrase parts move to the chorus at their next take
continuo ctl next                        # and to another groove
continuo ports                           # MIDI sources and destinations
continuo init                            # write the standard config to edit
```

`ctl` sends one line over UDP to 127.0.0.1:47130, so anything that can send a UDP packet can
steer the band: a controller script, Hammerspoon, a shell alias.

## Config

`continuo init` writes the standard config to `~/.config/continuo/config.json`:

- `inputs`: the MIDI sources whose notes make the chord. Each has an optional channel and an
  optional `zone` (the range of notes that count), so the left hand can play the chords while
  the right hand plays freely.
- `outputs`: Continuo's own virtual port (`"port": "virtual"`, it shows up as "continuo") or any
  destination by name (see `continuo ports`)
- `parts`: name, kind (`bass`, `comp`, `arp` or `drums`), style, output, channel, range, density,
  complexity, velocity, voices, swing, loop length, variation…
- `program`: a part setting (1-128) sent as a program change when the band starts and when
  a scene changes it. `examples/general-midi.json` uses it to pick General MIDI sounds per scene.
- `phrases`: a part setting: the styles whose phrases it plays (`"fusion"`, `"soul,jazz"`, `"any"`),
  or `"off"` for its style's pattern. Without a phrase bank parts play their patterns.
- `voicings`: a keys part setting: the bank's styles to voice from (`"jazz"`, `"fusion,soul"`),
  `"any"` (the default) or `"rules"` for the built-in voicer. The standard scenes pick a style each.
- `scenes`: per-part overrides, plus tempo and swing
- `clockOut`: outputs that get MIDI clock and start/stop, so a drum machine follows the band

Some hosts enable every new MIDI input automatically. When Continuo's port appears, make sure
each instrument listens only to its own part's channel.

## The voicing and phrase banks

`continuo mine` writes the voicings to `~/.config/continuo/bank.json` and the phrases to
`phrases.json` beside it, and `run` and `render` use them from there (`--bank` and `--phrases`
pick other files, `none` plays without one). It reads
standard MIDI files, a folder at a time, each under the style named by the `--tag` before it.
Drums and bass channels are skipped, and every other channel counts as one player. A shape
has to turn up twice (`--min`) to stay, and a pattern repeated over and over in one file
counts three times at most, so one loop can't drown out the rest.

For phrases, each track or channel of a file is one player: a bass line, keyboard chords, a
pad, or a single line, told apart by register, how often it plays chords, note lengths and
the track's name. Files up to 8 bars become one phrase; longer ones are cut into 4-bar
phrases, at most eight per player, spread through the song. The harmony under every half
bar comes from all the file's pitched players together. A file in a folder named after a
section (`…/GROOVE/VERSE/Variation_02.mid`) is that section's second take of GROOVE; other
files are songs of their own. A lone keyboard part's left-hand bass becomes a bass phrase,
so the bass part can play the pianist's own line. Only 4/4 for now.

The bank is built from your own MIDI files and stays on your machine: most commercial MIDI
packs allow use in your music but not sharing the files, and a bank is close enough to them
that it shouldn't be shared either.

## Rendering through your instruments

`render --sounds <file>` plays a rehearsal through instrument plugins instead of the built-in
General MIDI synth, one plugin per part, chosen per scene (`examples/arturia-sounds.json` uses
Arturia's V Collection; `"gm"` keeps a part on the built-in synth). Plugins play the patch they
open with and never get program changes. macOS only shows third-party plugins to processes in
your login session, so run it from a normal terminal; `continuo sounds` lists what it can see.

## Testing without sound

`continuo render` plays a progression into the engine on a simulated clock. It prints every
part bar by bar, checks the result and can write a MIDI file. The checks are that every note
ends, mono parts stay mono, and notes stay in range and in the chord's palette. `--late 30`
plays the chords 30 ms behind the beat, to hear how the band catches up. `swift test` runs
every style early, on time and late through slash chords and altered dominants.

## License

MIT
