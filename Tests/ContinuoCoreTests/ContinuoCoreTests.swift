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
