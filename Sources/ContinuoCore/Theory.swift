// Pitch classes, chord qualities with the scales they imply, naming a chord from the notes
// someone holds, and reading chord symbols ("Dm9", "B♭13", "Cmaj7/E").

import Foundation

public let noteNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

@inline(__always) public func mod12(_ x: Int) -> Int { ((x % 12) + 12) % 12 }

/// A MIDI note's name with C3 = 60, as Ableton, UVI and Yamaha print it.
public func noteName(_ note: Int) -> String {
    noteNames[mod12(note)] + String(Int((Double(note) / 12).rounded(.down)) - 2)
}

public struct Quality {
    public let suffix: String
    public let tones: [Int]     // intervals above the root, the 3rd and 7th first, the root last
    public let tensions: [Int]  // colors that suit the chord, best first
    public let scale: [Int]     // what passing notes and walking lines may use
}

private let ionian = [0, 2, 4, 5, 7, 9, 11], dorian = [0, 2, 3, 5, 7, 9, 10],
            mixolydian = [0, 2, 4, 5, 7, 9, 10], melodicMinor = [0, 2, 3, 5, 7, 9, 11],
            locrian2 = [0, 2, 3, 5, 6, 8, 10], halfWhole = [0, 1, 3, 4, 6, 7, 9, 10],
            wholeHalf = [0, 2, 3, 5, 6, 8, 9, 11], wholeTone = [0, 2, 4, 6, 8, 10],
            altered = [0, 1, 3, 4, 6, 8, 10], lydian = [0, 2, 4, 6, 7, 9, 11],
            lydianDominant = [0, 2, 4, 6, 7, 9, 10], lydianAugmented = [0, 2, 4, 6, 8, 9, 11],
            suspended = [0, 2, 5, 7, 9, 10]

// Simplest first: when two names fit the notes equally well, the earlier one wins.
public let qualities: [Quality] = [
    Quality(suffix: "",        tones: [4, 7, 0],           tensions: [2, 9],    scale: ionian),
    Quality(suffix: "m",       tones: [3, 7, 0],           tensions: [2, 5],    scale: dorian),
    Quality(suffix: "5",       tones: [7, 0],              tensions: [2, 5],    scale: [0, 2, 5, 7, 10]),
    Quality(suffix: "sus4",    tones: [5, 7, 0],           tensions: [2, 10],   scale: suspended),
    Quality(suffix: "sus2",    tones: [2, 7, 0],           tensions: [5, 9],    scale: suspended),
    Quality(suffix: "dim",     tones: [3, 6, 0],           tensions: [9, 2],    scale: wholeHalf),
    Quality(suffix: "aug",     tones: [4, 8, 0],           tensions: [2, 6],    scale: wholeTone),
    Quality(suffix: "6",       tones: [4, 9, 7, 0],        tensions: [2],       scale: ionian),
    Quality(suffix: "m6",      tones: [3, 9, 7, 0],        tensions: [2, 5],    scale: dorian),
    Quality(suffix: "7",       tones: [4, 10, 7, 0],       tensions: [2, 9],    scale: mixolydian),
    Quality(suffix: "maj7",    tones: [4, 11, 7, 0],       tensions: [2, 9],    scale: ionian),
    Quality(suffix: "m7",      tones: [3, 10, 7, 0],       tensions: [2, 5],    scale: dorian),
    Quality(suffix: "m7♭5",    tones: [3, 10, 6, 0],       tensions: [5, 8],    scale: locrian2),
    Quality(suffix: "dim7",    tones: [3, 9, 6, 0],        tensions: [2, 5, 8], scale: wholeHalf),
    Quality(suffix: "m(maj7)", tones: [3, 11, 7, 0],       tensions: [2, 5, 9], scale: melodicMinor),
    Quality(suffix: "7sus4",   tones: [5, 10, 7, 0],       tensions: [2, 9],    scale: suspended),
    Quality(suffix: "add9",    tones: [4, 2, 7, 0],        tensions: [9],       scale: ionian),
    Quality(suffix: "m(add9)", tones: [3, 2, 7, 0],        tensions: [5],       scale: dorian),
    Quality(suffix: "7♯5",     tones: [4, 10, 8, 0],       tensions: [2, 6],    scale: wholeTone),
    Quality(suffix: "maj7♯5",  tones: [4, 11, 8, 0],       tensions: [2, 6],    scale: lydianAugmented),
    Quality(suffix: "6/9",     tones: [4, 9, 2, 7, 0],     tensions: [],        scale: ionian),
    Quality(suffix: "m6/9",    tones: [3, 9, 2, 7, 0],     tensions: [5],       scale: dorian),
    Quality(suffix: "9",       tones: [4, 10, 2, 7, 0],    tensions: [9],       scale: mixolydian),
    Quality(suffix: "maj9",    tones: [4, 11, 2, 7, 0],    tensions: [9],       scale: ionian),
    Quality(suffix: "m9",      tones: [3, 10, 2, 7, 0],    tensions: [5],       scale: dorian),
    Quality(suffix: "9sus4",   tones: [5, 10, 2, 7, 0],    tensions: [9],       scale: suspended),
    Quality(suffix: "7♭9",     tones: [4, 10, 1, 7, 0],    tensions: [9, 3],    scale: halfWhole),
    Quality(suffix: "7♯9",     tones: [4, 10, 3, 7, 0],    tensions: [8, 1],    scale: altered),
    Quality(suffix: "7♯11",    tones: [4, 10, 6, 7, 0],    tensions: [2, 9],    scale: lydianDominant),
    Quality(suffix: "7alt",    tones: [4, 10, 3, 8, 0],    tensions: [1, 6],    scale: altered),
    Quality(suffix: "maj7♯11", tones: [4, 11, 6, 7, 0],    tensions: [2, 9],    scale: lydian),
    Quality(suffix: "m11",     tones: [3, 10, 5, 2, 7, 0], tensions: [9],       scale: dorian),
    Quality(suffix: "13",      tones: [4, 10, 9, 2, 7, 0], tensions: [],        scale: mixolydian),
    Quality(suffix: "maj13",   tones: [4, 11, 9, 2, 7, 0], tensions: [6],       scale: lydian),
    Quality(suffix: "m13",     tones: [3, 10, 9, 2, 7, 0], tensions: [5],       scale: dorian),
]

public struct Chord: Equatable, CustomStringConvertible {
    public let root: Int     // pitch class
    public let quality: Int  // index into qualities
    public let bass: Int     // pitch class of the lowest note: the root unless it's a slash chord

    public init(root: Int, quality: Int, bass: Int? = nil) {
        self.root = mod12(root)
        self.quality = quality
        self.bass = mod12(bass ?? root)
    }

    public var q: Quality { qualities[quality] }
    public var description: String { noteNames[root] + q.suffix + (bass == root ? "" : "/" + noteNames[bass]) }
    public var tones: [Int] { q.tones.map { mod12(root + $0) } }
    public var tensions: [Int] { q.tensions.map { mod12(root + $0) } }
    public var scale: [Int] { q.scale.map { mod12(root + $0) } }

    /// Root, third, fifth and seventh (or sixth): the chord without its extensions.
    public var core: [Int] { q.tones.filter { $0 == 0 || $0 == q.tones[0] || $0 == q.tones[1] || $0 == fifth } }

    /// The pitch classes a part may use as complexity rises: the core of the chord, every note
    /// of it, then its tensions, then the whole scale.
    public func palette(_ complexity: Double) -> Set<Int> {
        var intervals = Set(complexity < 0.35 ? core : q.tones)
        if complexity >= 0.6 { intervals.formUnion(q.tensions.prefix(complexity >= 0.75 ? 2 : 1)) }
        if complexity >= 0.85 { intervals.formUnion(q.scale) }
        return Set(intervals.map { mod12(root + $0) })
    }

    /// The chord's fifth as an interval: perfect unless the chord bends it.
    public var fifth: Int { q.tones.contains(7) ? 7 : q.tones.contains(6) ? 6 : q.tones.contains(8) ? 8 : 7 }
    /// Its seventh (or sixth), or an octave when it has neither.
    public var seventh: Int { q.tones.contains(10) ? 10 : q.tones.contains(11) ? 11 : q.tones.contains(9) ? 9 : 12 }
}

/// Names the chord in a set of held notes. The lowest note counts as the root when it can,
/// as on an arranger keyboard, so E G B♭ D reads Em7♭5, not a rootless C9; it reads as a
/// slash chord when another root fits clearly better (E G C is C/E).
public func detectChord(_ notes: [Int]) -> Chord? {
    guard let low = notes.min() else { return nil }
    let held = Set(notes.map(mod12)), bass = mod12(low)
    var best: (score: Double, chord: Chord)? = nil
    for root in 0..<12 {
        let rel = Set(held.map { mod12($0 - root) })
        for (i, q) in qualities.enumerated() {
            let tones = Set(q.tones)
            var score = 10 * Double(rel.intersection(tones).count) - 7 * Double(rel.subtracting(tones).count)
            for m in tones.subtracting(rel) {
                score -= m == 0 ? 2 : m == 7 ? 1 : (m == q.tones[0] && (m == 3 || m == 4)) ? 6 : 9
            }
            score += root == bass ? 5 : -2   // a slash chord needs a clearly better fit
            if !rel.contains(0) { score -= 1 }
            score -= 0.3 * Double(q.tones.count)
            if best == nil || score > best!.score + 1e-9 { best = (score, Chord(root: root, quality: i, bass: bass)) }
        }
    }
    return best?.chord
}

private let aliases: [String: String] = [
    "maj": "", "M": "", "min": "m", "-": "m", "M7": "maj7", "Δ": "maj7", "Δ7": "maj7", "ma7": "maj7",
    "-7": "m7", "min7": "m7", "ø": "m7♭5", "ø7": "m7♭5", "°": "dim", "o": "dim", "°7": "dim7", "o7": "dim7",
    "+": "aug", "+7": "7♯5", "aug7": "7♯5", "mmaj7": "m(maj7)", "mM7": "m(maj7)", "madd9": "m(add9)",
    "sus": "sus4", "7sus": "7sus4", "9sus": "9sus4", "11": "9sus4", "69": "6/9", "m69": "m6/9",
    "M9": "maj9", "M13": "maj13", "maj7♯11": "maj7♯11", "add2": "add9", "2": "sus2",
]

/// The pitch class of a note name such as "B♭", "F#" or "eb", and what follows it.
func parseNoteName<S: StringProtocol>(_ text: S) -> (Int, S.SubSequence)? {
    guard let first = text.first, let letter = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][first.uppercased()] else { return nil }
    var rest = text.dropFirst(), pc = letter
    if let a = rest.first, "b♭#♯".contains(a) { pc += (a == "b" || a == "♭") ? -1 : 1; rest = rest.dropFirst() }
    return (mod12(pc), rest)
}

/// Reads a chord symbol: "Dm9", "Bb13", "F#m7b5", "Cmaj7/E", "Eø", "A7alt", "C6/9".
public func parseChord(_ text: String) -> Chord? {
    guard let (root, rest) = parseNoteName(text.trimmingCharacters(in: .whitespaces)) else { return nil }
    var suffix = String(rest), bass: Int? = nil
    if let slash = suffix.lastIndex(of: "/"), let (b, tail) = parseNoteName(suffix[suffix.index(after: slash)...]), tail.isEmpty {
        bass = b
        suffix = String(suffix[..<slash])
    }
    suffix = suffix.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯")
    suffix = aliases[suffix] ?? suffix
    guard let quality = qualities.firstIndex(where: { $0.suffix == suffix }) else { return nil }
    return Chord(root: root, quality: quality, bass: bass)
}

/// A note given as a MIDI number or a name with an octave, C3 = 60 ("D2", "F#3", "Bb1").
public func parseNote(_ text: String) -> Int? {
    if let n = Int(text), (0...127).contains(n) { return n }
    guard let (pc, rest) = parseNoteName(text), let octave = Int(rest) else { return nil }
    let n = (octave + 2) * 12 + pc
    return (0...127).contains(n) ? n : nil
}

/// A plain left-hand voicing of a chord: its bass note between C2 and B2, the rest stacked
/// above it within about an octave and a half. Used to play chord symbols into the engine.
public func leftHand(_ chord: Chord) -> [Int] {
    let bass = 48 + mod12(chord.bass - 48)
    var notes = [bass], top = bass
    for i in chord.q.tones.sorted() where mod12(chord.root + i) != chord.bass {
        let pc = mod12(chord.root + i)
        top += mod12(pc - top) == 0 ? 12 : mod12(pc - top)
        notes.append(top)
    }
    return notes
}
