// The rhythms the parts play. A style is a bar (or two) of sixteenths written as text:
//
//   hits   a digit starts a note and says how strong that step is (9 the downbeat, 1 a ghost),
//          "-" holds the note before it one more sixteenth, "." is a rest
//   roles  what each note is. Bass: R root (the slash note on a slash chord), L root an octave
//          down, O octave, 5 fifth, 3 third, 7 seventh, A approach (a half step into the root),
//          S scale step into the root, G ghost (the last note again, short and soft), W walking
//          step, T ninth. Comp: C the whole voicing, T its top, S the shell (3rd and 7th),
//          B its bottom. Arps take their notes from the order instead.
//
// Density keeps the strong steps and drops the weak ones first, so turning it down thins a
// groove the way a player would. Complexity lets the richer bass roles through (fifths, then
// ghosts and approach notes, then thirds and sevenths); below their level they fall back to
// the root, and ghosts drop out.

public enum Kind: String, Codable, CaseIterable { case bass, comp, arp }

/// How an arp walks the notes of the chord, given the hit count `i` and `n` notes.
public enum Order: Equatable {
    case up, down, upDown, skip, converge, pedal, random
    case figure([Int])

    func index(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        switch self {
        case .up: return i % n
        case .down: return n - 1 - i % n
        case .upDown: let j = i % (2 * n - 2); return j < n ? j : 2 * n - 2 - j
        case .skip: return (i / 2 + (i % 2) * 2) % n             // 0 2 1 3 2 4 …
        case .converge: let j = i % n; return j % 2 == 0 ? j / 2 : n - 1 - j / 2
        case .pedal: return i % 2 == 0 ? n - 1 : (i / 2) % (n - 1)  // the top note between the others
        case .random: return 0                                    // chosen by the engine's dice
        case .figure(let f): return f[i % f.count] % n
        }
    }
}

public struct Onset: Equatable {
    public let step: Int
    public let weight: Int
    public let length: Int    // in sixteenths, ties included
    public let role: Character
}

public struct Style {
    public let name: String
    public let kind: Kind
    public let onsets: [Onset?]   // one slot per sixteenth
    public let order: Order
    public let gate: Double       // how much of its length a note sounds
    public let about: String
    public var steps: Int { onsets.count }

    init(_ name: String, _ kind: Kind, _ hits: String, _ roles: String = "", order: Order = .up, gate: Double, _ about: String) {
        let h = Array(hits.filter { $0 != " " }), r = Array(roles.filter { $0 != " " })
        precondition(r.isEmpty || r.count == h.count, "style \(name): roles and hits differ in length")
        let fallback: Character = kind == .bass ? "R" : kind == .comp ? "C" : "N"
        var onsets = [Onset?](repeating: nil, count: h.count)
        var i = 0
        while i < h.count {
            guard let w = h[i].wholeNumberValue else { i += 1; continue }
            var length = 1
            while i + length < h.count && h[i + length] == "-" { length += 1 }
            onsets[i] = Onset(step: i, weight: w, length: length, role: r.isEmpty || r[i] == "." ? fallback : r[i])
            i += length
        }
        (self.name, self.kind, self.onsets, self.order, self.gate, self.about) = (name, kind, onsets, order, gate, about)
    }
}

public let styles: [Style] = [
    // bass
    Style("pedal", .bass,    "9.5. 7.5. 8.5. 7.4.", "R.R. R.R. R.O. 5.A.", gate: 0.7,
          "driving eighths on the root; octave, fifth and a pickup with complexity"),
    Style("rootfive", .bass, "9-.3 6-.3 8-.3 6-.4", "R..O 5..O R..O 5..A", gate: 0.85,
          "root and fifth on the beats, octave pickups when dense"),
    Style("funk", .bass,     "9.36 ..7. 8.4. 6.35", "R.GR ..O. 5.G. R.GA", gate: 0.6,
          "syncopated sixteenths with ghosts and an approach note"),
    Style("octaves", .bass,  "9.7. 8.7. 8.7. 8.73", "R.O. R.O. R.O. R.OA", gate: 0.5,
          "disco octaves"),
    Style("walk", .bass,     "9--- 7--- 8--- 6---", "R... W... W... A...", gate: 0.9,
          "walking quarter notes into the next root (chord tones; scale steps with complexity)"),
    Style("bossa", .bass,    "9--- --7- 8--- --6-", "R... ..5. 5... ..R.", gate: 0.9,
          "bossa nova: root and fifth, dotted quarter and eighth"),
    Style("tresillo", .bass, "9--7 --8- 9--7 --6-", "R..5 ..O. R..5 ..A.", gate: 0.8,
          "3+3+2"),
    Style("dub", .bass,      "9--- --.6 -.7- -.5.", "R... ...5 ..O. ..A.", gate: 0.9,
          "a long root and a little answer"),
    Style("pump", .bass,     "9343 8343 9343 8345", "RRRR ORRR RRRR ORRA", gate: 0.45,
          "pumping sixteenths"),

    // comp
    Style("pad", .comp,        "9--- ---- ---- ----", gate: 1.0,
          "held chords, voices moving to the next chord"),
    Style("halves", .comp,     "9--- ---- 7--- ----", gate: 1.0,
          "half notes"),
    Style("charleston", .comp, "9-.. ..7- .... 5-..", "C... ..C. .... T...", gate: 0.8,
          "beat one and the and of two, a light top on four"),
    Style("skank", .comp,      ".... 9-.. .... 8-..", gate: 0.6,
          "two and four"),
    Style("offbeat", .comp,    "..9. ..7. ..8. ..7.", gate: 0.35,
          "house stabs on the offbeats"),
    Style("stabs", .comp,      "9..5 ..7. ..6. 8..4", "C..T ..C. ..T. C..T", gate: 0.4,
          "funk stabs, the top voices on the weak ones"),
    Style("funk16", .comp,     "9363 7363 8363 7363", "CTST CTST CTST CTST", gate: 0.3,
          "sixteenth chops"),
    Style("bossa", .comp,      "9..6 ..7. ..6. .7.. ..6. .7.. 8... 6...", gate: 0.6,
          "two-bar bossa nova comping"),
    Style("gate", .comp,       "9696 9696 9696 9696", gate: 0.45,
          "trance gate"),
    Style("ballad", .comp,     "9--- ---- 6--- 5---", "C... .... T... S...", gate: 0.95,
          "a held chord, the top on three, the shell on four"),

    // arp
    Style("up16", .arp,    "9353 7353 8353 7353", order: .up, gate: 0.5, "sixteenths upward"),
    Style("updown8", .arp, "9.5. 7.5. 8.5. 7.5.", order: .upDown, gate: 0.6, "eighths up and down"),
    Style("broken", .arp,  "9353 7353 8353 7353", order: .skip, gate: 0.5, "broken chord, 1 3 2 4"),
    Style("threes", .arp,  "9..", order: .up, gate: 0.6, "every third sixteenth, across the bar line"),
    Style("pedal", .arp,   "9353 7353 8353 7353", order: .pedal, gate: 0.45, "the top note between the others"),
    Style("random", .arp,  "9353 7353 8353 7353", order: .random, gate: 0.45, "a random riff that repeats every loop"),
    Style("euclid", .arp,  "9.67 .78. 9.67 .78.", order: .converge, gate: 0.5, "five in eight, outside in"),
    Style("riff", .arp,    "9.63 7.6. 8.63 7.54", order: .figure([0, 2, 1, 3, 2, 4, 3, 1]), gate: 0.5,
          "a fixed figure"),
]

public func style(named name: String, kind: Kind) -> Style? {
    styles.first { $0.kind == kind && $0.name == name }
}
