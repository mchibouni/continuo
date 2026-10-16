import XCTest
@testable import ContinuoCore

final class ContinuoCoreTests: XCTestCase {
    func name(_ notes: String) -> String {
        detectChord(notes.split(separator: " ").map { parseNote(String($0))! })!.description
    }

    func testNamesChords() {
        XCTAssertEqual(name("C3 E3 G3"), "C")
        XCTAssertEqual(name("D2 F2 A2 C3 E3"), "Dm9")
        XCTAssertEqual(name("E2 G2 B♭2 D3"), "Em7♭5")
        XCTAssertEqual(name("E2 G2 C3"), "C/E")
        XCTAssertEqual(name("C3 B♭3"), "C7")
        XCTAssertEqual(name("C2 E2 B♭2 D3 A3"), "C13")
        XCTAssertEqual(name("A2 C♯3 G3 C4 F4"), "A7alt")
        XCTAssertEqual(name("A1 G2 C3 E3"), "Am7")
    }

    func testReadsSymbols() {
        for (text, expect) in [("Dm9", "Dm9"), ("Bb13", "B♭13"), ("F#m7b5", "F♯m7♭5"), ("Cmaj7/E", "Cmaj7/E"),
                               ("Eø", "Em7♭5"), ("C6/9", "C6/9"), ("A7alt", "A7alt"), ("Gsus", "Gsus4")] {
            XCTAssertEqual(parseChord(text)?.description, expect, text)
        }
        XCTAssertNil(parseChord("H7"))
        // a chord played as its left hand names itself back
        for q in qualities.indices {
            let c = Chord(root: 2, quality: q)
            let back = detectChord(leftHand(c))!
            XCTAssertEqual(Set(back.tones), Set(c.tones), "\(c) came back as \(back)")
        }
    }

    func testStylesAreWellFormed() {
        for s in styles {
            XCTAssertFalse(s.onsets.compactMap { $0 }.isEmpty, s.name)
            for o in s.onsets.compactMap({ $0 }) where s.kind == .bass {
                XCTAssertTrue("RLO53 7ASGWT".contains(o.role), "\(s.name) role \(o.role)")
            }
        }
    }

    func testVoicesMoveLittle() {
        var previous: [Int] = []
        var moves: [Int] = []
        for symbol in ["Dm7", "G7", "Cmaj7", "A7", "Dm7"] {
            let v = voice(parseChord(symbol)!, voices: 4, lo: 52, hi: 79, complexity: 0.6, rootless: true, previous: previous)
            XCTAssertEqual(v.count, 4)
            if !previous.isEmpty { moves.append(zip(v, previous).map { abs($0 - $1) }.reduce(0, +)) }
            previous = v
        }
        XCTAssertLessThanOrEqual(moves.max()!, 6, "voices jump: \(moves)")
    }

    // Every style of every kind, through a progression with slash chords and altered
    // dominants, early, on time and late: no stuck or doubled notes, mono stays mono, ranges
    // and harmony hold.
    func testEveryStyleRehearsesClean() throws {
        let chords = ["Am7", "D9", "Gmaj7/B", "E7alt", "Fmaj7♯11", "Bm7♭5", "E7♭9", "Am(maj7)"].map { parseChord($0)! }
        for s in styles {
            var config = Config.standard
            config.startScene = nil
            config.scenes = nil
            config.parts = [PartSpec(name: "x", kind: s.kind, style: s.name, out: "continuo", channel: 2, vary: 0.5)]
            for late in [-0.02, 0, 0.035] {
                let r = try rehearse(config, chords: chords, late: late)
                XCTAssertEqual(r.problems, [], "\(s.kind) \(s.name), late \(late)")
                XCTAssertFalse(r.noteOns.isEmpty, "\(s.kind) \(s.name) played nothing")
            }
        }
    }

    func testScenesRehearseClean() throws {
        for scene in Config.standard.scenes! {
            let r = try rehearse(Config.standard, chords: ["Dm9", "G13", "Cmaj9", "A7alt"].map { parseChord($0)! }, loops: 2, scene: scene.name)
            XCTAssertEqual(r.problems, [], scene.name)
        }
    }

    func testPlayingEarlyNeedsNoCorrections() throws {
        let r = try rehearse(Config.standard, chords: ["Am7", "D9", "Gmaj7", "E7alt"].map { parseChord($0)! }, loops: 2, late: -0.01)
        XCTAssertEqual(r.engine.corrections, 0)
    }

    // A type 0 MIDI file at 120 BPM, one chord per beat, each held most of a beat.
    func smf(_ chords: [[Int]]) -> Data {
        func vlq(_ v: Int) -> [UInt8] {
            var v = v, out = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            return out
        }
        var track: [UInt8] = [0, 0xFF, 0x51, 3, 0x07, 0xA1, 0x20]
        for (j, c) in chords.enumerated() {
            // rolled 5 ticks a note, held 400 ticks, the next chord on the next beat
            for (i, n) in c.enumerated() { track += vlq(i > 0 ? 5 : j > 0 ? 80 - 5 * (c.count - 1) : 0) + [0x90, UInt8(n), 80] }
            for (i, n) in c.enumerated() { track += vlq(i == 0 ? 400 : 0) + [0x80, UInt8(n), 0] }
        }
        track += [0, 0xFF, 0x2F, 0]
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } }
        return Data(Array("MThd".utf8) + be(6, 4) + be(0, 2) + be(1, 2) + be(480, 2) + Array("MTrk".utf8) + be(track.count, 4) + track)
    }

    func testReadsBackItsOwnMIDIFiles() throws {
        let r = try rehearse(Config.standard, chords: ["Dm9", "G13"].map { parseChord($0)! })
        let file = try MIDIFile(r.midiFile)
        XCTAssertEqual(file.notes.count, r.noteOns.count)
        XCTAssertEqual(file.tempo, r.engine.tempo, accuracy: 0.5)
        let first = r.noteOns.map(\.time).min()! - r.start
        XCTAssertEqual(file.notes[0].start, first, accuracy: 0.003)
    }

    func testMinesAndPlaysPlayersVoicings() throws {
        // a left-hand D under F A C E, three times, and G under F B E A: Dm9 and G13 as pianists play them
        let dm9 = [38, 65, 69, 72, 76], g13 = [43, 65, 71, 76, 81]
        var miner = VoicingMiner()
        miner.add(try MIDIFile(smf([dm9, g13, dm9, g13, dm9, g13])), tag: "jazz")
        let bank = miner.bank()
        XCTAssertEqual(bank.files["jazz"], 1)
        let d = parseChord("Dm9")!, g = parseChord("G13")!
        XCTAssertEqual(bank.shapes(for: d).first?.notes, [65, 69, 72, 76])
        XCTAssertEqual(bank.voice(d, voices: 4, lo: 52, hi: 79, complexity: 0.6, rootless: true, tags: ["soul"], previous: []),
                       [65, 69, 72, 76], "a style with no voicings falls back to the others")
        XCTAssertEqual(bank.voice(g, voices: 4, lo: 52, hi: 84, complexity: 0.6, rootless: true, tags: nil, previous: [65, 69, 72, 76]),
                       [65, 71, 76, 81])
        XCTAssertNil(bank.voice(parseChord("C7alt")!, voices: 4, lo: 52, hi: 79, complexity: 0.6, rootless: true, tags: nil, previous: []))

        // the keys part plays them in a rehearsal, and only uses the rules when told to
        var config = Config.standard
        config.startScene = nil
        config.scenes = nil
        config.parts = [PartSpec(name: "keys", kind: .comp, style: "pad", out: "continuo", channel: 3, range: [52, 84])]
        let r = try rehearse(config, chords: [d, g], late: -0.01, bank: bank)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(Set(r.noteOns.map { Int($0.bytes[1]) }), Set([65, 69, 72, 76, 71, 81]))
        config.parts[0].voicings = "rules"
        let rules = try rehearse(config, chords: [d, g], late: -0.01, bank: bank)
        XCTAssertNotEqual(Set(rules.noteOns.map { Int($0.bytes[1]) }), Set([65, 69, 72, 76, 71, 81]))
    }

    func testNotesKeepTheirJobInANewChord() {
        func moved(_ note: Int, from: String, to: String) -> Int {
            let a = parseChord(from)!, b = parseChord(to)!
            let j = job(a, mod12(note - a.root))
            return mod12(b.root + interval(b, j.deg, j.alt))
        }
        XCTAssertEqual(moved(64, from: "Cmaj7", to: "Dm7"), mod12(65))      // the 3rd: E → F
        XCTAssertEqual(moved(70, from: "C7", to: "Fmaj7"), mod12(64))       // the 7th: B♭ → E
        XCTAssertEqual(moved(61, from: "C7♭9", to: "Dm9"), mod12(64))       // a ♭9 over a minor chord is a plain 9
        XCTAssertEqual(moved(61, from: "C7♭9", to: "G7♭9"), mod12(68))      // and stays flat where the chord has it
        XCTAssertEqual(moved(70, from: "C7", to: "F"), mod12(65))           // a plain triad keeps no 7th: the root
        XCTAssertEqual(moved(69, from: "C13", to: "A7alt"), mod12(77))      // a 13th over an altered dominant: its ♭13
        // a phrase over C moves to D♭ as a whole, keeping its shape
        let notes = [60, 64, 67, 72].map { p in
            PhraseNote(t: 0, d: 1, v: 90, p: p, deg: job(parseChord("C")!, mod12(p)).deg, alt: 0, root: 0, to: nil)
        }
        let phrase = Phrase(tag: "t", role: .keys, song: "s", section: "", order: 0, name: "n", tempo: 100, bars: 1, notes: notes)
        XCTAssertEqual(notes.indices.map { phrase.place($0, over: parseChord("D♭maj7")!, offset: 0) }, [61, 65, 68, 73])
    }

    // Two players, bass and keys, one bar each of C and F, four times: a band groove to follow.
    func twoPlayerSMF() -> Data {
        func vlq(_ v: Int) -> [UInt8] {
            var v = v, out = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            return out
        }
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } }
        func track(_ name: String, _ ch: UInt8, _ events: [(Int, Int, Int)]) -> [UInt8] {   // start, length (ticks), note
            var evs: [(Int, [UInt8])] = []
            for (s, l, n) in events { evs.append((s, [0x90 | ch, UInt8(n), 90])); evs.append((s + l, [0x80 | ch, UInt8(n), 0])) }
            evs.sort { ($0.0, $0.1[0] & 0xF0 == 0x90 ? 1 : 0) < ($1.0, $1.1[0] & 0xF0 == 0x90 ? 1 : 0) }
            var body: [UInt8] = [0, 0xFF, 0x03, UInt8(name.utf8.count)] + Array(name.utf8), last = 0
            for (t, m) in evs { body += vlq(t - last) + m; last = t }
            body += [0, 0xFF, 0x2F, 0]
            return Array("MTrk".utf8) + be(body.count, 4) + body
        }
        let conductor: [UInt8] = [0, 0xFF, 0x51, 3, 0x07, 0xA1, 0x20, 0, 0xFF, 0x58, 4, 4, 2, 24, 8, 0, 0xFF, 0x2F, 0]
        var bass: [(Int, Int, Int)] = [], keys: [(Int, Int, Int)] = []
        for bar in 0..<8 {
            let root = bar % 2 == 0 ? 36 : 41, t = bar * 1920
            bass += [(t, 400, root), (t + 720, 200, root + 7), (t + 960, 400, root + 12), (t + 1680, 200, root + 10)]
            let chord = bar % 2 == 0 ? [64, 67, 71, 74] : [65, 69, 72, 76]
            for beat in [480, 1440] { keys += chord.map { (t + beat, 300, $0) } }
        }
        let tracks = Array("MTrk".utf8) + be(conductor.count, 4) + conductor + track("Bass", 0, bass) + track("Keys", 1, keys)
        return Data(Array("MThd".utf8) + be(6, 4) + be(1, 2) + be(3, 2) + be(480, 2) + tracks)
    }

    func testMinesAPhraseGrooveAndPlaysItOverOtherChords() throws {
        var miner = PhraseMiner()
        miner.add(try MIDIFile(twoPlayerSMF()), tag: "test", song: "groove", section: "", name: "groove.mid")
        let bank = miner.bank
        XCTAssertEqual(Set(bank.phrases.map(\.role)), [.bass, .keys])
        let bassPhrase = bank.phrases.first { $0.role == .bass }!
        XCTAssertEqual(bassPhrase.notes.prefix(4).map(\.deg), [0, 4, 0, 6], "root, fifth, octave, seventh")

        var config = Config.standard
        config.startScene = nil
        config.scenes = nil
        config.parts = [PartSpec(name: "bass", kind: .bass, style: "funk", out: "continuo", channel: 2, phrases: "test"),
                        PartSpec(name: "keys", kind: .comp, style: "stabs", out: "continuo", channel: 3, phrases: "test")]
        var log: [String] = []
        let r = try rehearse(config, chords: ["Dm9", "G13", "Cmaj9", "A7alt"].map { parseChord($0)! }, loops: 2, late: -0.01,
                             phrases: bank, log: { log.append($0) })
        XCTAssertEqual(r.problems, [])
        XCTAssertTrue(log.contains { $0.hasPrefix("band: groove") }, "\(log)")
        let bassOns = r.noteOns.filter { r.engine.parts[$0.part].name == "bass" }
        XCTAssertGreaterThan(bassOns.count, 16)
        // on each chord's downbeat the bass plays that chord's bass note, as the groove's player did
        for (t, c) in r.chords {
            if let first = bassOns.first(where: { abs($0.time - t) < 0.08 }) { XCTAssertEqual(mod12(Int(first.bytes[1])), c.bass, "\(c)") }
        }
    }

    func testSetCommand() throws {
        let e = try Engine(config: Config.standard, sink: Recorder())
        XCTAssertTrue(e.control("set bass.density 0.3", at: 0).contains("density 0.30"))
        XCTAssertTrue(e.control("set keys.range 48 72", at: 0).contains("C2-C4"))
        XCTAssertTrue(e.control("set keys.style charleston", at: 0).contains("charleston"))
        XCTAssertTrue(e.control("set bass.wobble 1", at: 0).hasPrefix("error"))
        XCTAssertTrue(e.control("set keys.style polka", at: 0).hasPrefix("error"))
        XCTAssertTrue(e.control("scene jazz", at: 0).contains("jazz"))
        XCTAssertEqual(e.part("bass")!.density, 0.75)   // a scene starts from the config again
    }
}
