// Voicings players actually use, learned from MIDI files. Mining finds every moment a player
// struck a chord, names the chord, sets the left-hand bass aside and keeps the rest as a shape:
// the notes above the root, spacing and all, tagged with the style it came from and counted.
// A keys part then plays the shape that moves best from its last voicing, so its chords sound
// like a player's instead of a rule's.

import Foundation

public struct VoicingBank: Codable {
    public struct Shape: Codable {
        public var q: String     // the chord quality's suffix ("m9", "7alt", "" for major)
        public var bass: Int     // the bass above the root, 0 unless it was a slash chord
        public var iv: [Int]     // the notes above the root, lowest first; iv[0] is 0-11
        public var tag: String   // the style it came from
        public var n: Int        // how often players used it
        public var at: Int       // where players put its lowest note, on average
    }
    public var shapes: [Shape]
    public var files: [String: Int]   // files read, by tag

    var index: [String: [Int]] = [:]   // "quality|bass" → indices into shapes
    var most: [String: Int] = [:]      // the most-used count per key

    enum CodingKeys: String, CodingKey { case shapes, files }

    public init(shapes: [Shape], files: [String: Int]) {
        (self.shapes, self.files) = (shapes, files)
        buildIndex()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shapes = try c.decode([Shape].self, forKey: .shapes)
        files = try c.decode([String: Int].self, forKey: .files)
        buildIndex()
    }

    public static func load(_ url: URL) throws -> VoicingBank {
        try JSONDecoder().decode(VoicingBank.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: url)
    }

    public var tags: [String] { Array(Set(shapes.map(\.tag))).sorted() }

    mutating func buildIndex() {
        index = [:]; most = [:]
        for (i, s) in shapes.enumerated() {
            let k = "\(s.q)|\(s.bass)"
            index[k, default: []].append(i)
            most[k] = max(most[k] ?? 0, s.n)
        }
    }

    /// The shapes for a chord from the given styles (any style when none of them has one),
    /// the exact slash chord first, else the chord over its root.
    func candidates(_ chord: Chord, tags: Set<String>?) -> [Int] {
        for bass in Set([mod12(chord.bass - chord.root), 0]).sorted(by: >) {
            let all = index["\(chord.q.suffix)|\(bass)"] ?? []
            if let tags {
                let tagged = all.filter { tags.contains(shapes[$0].tag) }
                if !tagged.isEmpty { return tagged }
            }
            if !all.isEmpty { return all }
        }
        return []
    }

    /// The players' shapes for a chord, most used first, where they played them.
    public func shapes(for chord: Chord, tags: Set<String>? = nil) -> [(notes: [Int], n: Int, tag: String)] {
        candidates(chord, tags: tags).map { shapes[$0] }.sorted { $0.n > $1.n }.map { s in
            let base = s.at - s.iv[0]
            let ref = base + mod12(chord.root - base + 6) - 6   // the root nearest where they played it
            return (s.iv.map { ref + $0 }, s.n, s.tag)
        }
    }

    /// The best player's voicing for a chord on a keys part, or nil when the bank has none that
    /// fits the range. The same tests as the rule-based voicer: move little from the last
    /// voicing, stay near the middle of the range, keep low notes apart. On top of that, prefer
    /// shapes players used often, where they played them, with about `voices` notes.
    public func voice(_ chord: Chord, voices: Int, lo: Int, hi: Int, complexity: Double,
                      rootless: Bool, tags: Set<String>?, previous: [Int]) -> [Int]? {
        let key = "\(chord.q.suffix)|\(mod12(chord.bass - chord.root))"
        let found = candidates(chord, tags: tags)
        guard !found.isEmpty else { return nil }
        let top = Double(most[key] ?? found.map { shapes[$0].n }.max()!)
        let center = Double(lo + hi) / 2
        let colors = Set(chord.q.tones.filter { $0 != 0 && $0 != 7 })
        let flatNine = chord.q.tones.contains(1)
        var best: [Int]? = nil, bestCost = Double.infinity

        for i in found {
            let s = shapes[i]
            let rare = 1.5 * log(top / Double(max(1, s.n)))
            // every octave of the shape that fits the range
            var ref = lo - s.iv[0] + mod12(chord.root - (lo - s.iv[0]))
            while ref + s.iv.last! <= hi {
                let notes = s.iv.map { ref + $0 }
                ref += 12
                guard notes[0] >= lo else { continue }
                let mean = Double(notes.reduce(0, +)) / Double(notes.count)
                var cost = rare + 1.2 * Double(abs(notes.count - voices)) + 0.15 * Double(abs(notes[0] - s.at))
                if previous.isEmpty {
                    cost += abs(mean - center)
                } else {
                    for n in notes { cost += Double(previous.map { abs($0 - n) }.min()!) }
                    for p in previous { cost += Double(notes.map { abs($0 - p) }.min()!) }
                    cost += 0.5 * Double(abs(notes.last! - previous.max()!)) + 0.25 * abs(mean - center)
                }
                for (a, b) in zip(notes, notes.dropFirst()) {
                    let d = b - a
                    if (d < 3 && a < 55) || (d < 5 && a < 48) || (d < 7 && a < 41) { cost += 5 }   // mud
                }
                for x in 0..<notes.count {
                    for y in (x + 1)..<notes.count where notes[y] - notes[x] == 13 && !flatNine { cost += 6 }
                }
                if rootless && mod12(notes[0] - chord.root) == 0 { cost += 2 }   // the bass part has the root
                // plain chords when complexity is low, colors when it's high
                let extra = notes.filter { !chord.q.tones.contains(mod12($0 - chord.root)) }.count
                if complexity < 0.4 { cost += Double(extra) * (0.4 - complexity) * 5 }
                if complexity > 0.7 { cost -= Double(extra) * (complexity - 0.7) * 2 }
                if !notes.contains(where: { colors.contains(mod12($0 - chord.root)) }) { cost += 3 }
                if cost < bestCost - 1e-9 { bestCost = cost; best = notes }
            }
        }
        return best
    }
}

/// Builds a bank from MIDI files: `add` each file with the style it represents, then `bank`.
public struct VoicingMiner {
    struct Key: Hashable { let q: String, bass: Int, iv: [Int], tag: String }
    var counts: [Key: (n: Int, at: Int)] = [:]
    var files: [String: Int] = [:]
    public private(set) var strikes = 0, kept = 0
    var named: [Int: Chord?] = [:]   // chord names by (pitch-class set, bass) — the same sets come back a lot

    public init() {}

    /// Learns the chords in one file. Drums (channel 10) and bass programs are skipped; every
    /// other channel is read on its own, as one player.
    public mutating func add(_ file: MIDIFile, tag: String) {
        files[tag, default: 0] += 1
        var perFile: [Key: Int] = [:]
        let byChannel = Dictionary(grouping: file.notes) { $0.channel }
        for (channel, notes) in byChannel where channel != 9 {
            if let p = file.programs[channel], (32...39).contains(p) { continue }
            var i = 0
            while i < notes.count {
                // a strike: notes that start within 35 ms of the first, as a hand plays a chord
                var j = i + 1
                while j < notes.count && notes[j].start - notes[i].start < 0.035 { j += 1 }
                defer { i = j }
                guard j - i >= 2 else { continue }
                let t = notes[i].start
                var sounding = Set(notes[i..<j].map(\.note))
                // what the other hand still holds: a bass or a chord struck just before
                var k = i - 1
                while k >= 0 && t - notes[k].start < 8 {
                    if notes[k].start + notes[k].length > t + 0.05 { sounding.insert(notes[k].note) }
                    k -= 1
                }
                strikes += 1
                guard let key = learn(sounding.sorted(), tag: tag) else { continue }
                // a pattern struck over and over in one file counts three times at most
                perFile[key, default: 0] += 1
                guard perFile[key]! <= 3 else { continue }
                kept += 1
                let at = upper(sounding.sorted())[0]
                let old = counts[key] ?? (0, 0)
                counts[key] = (old.n + 1, old.at + at)
            }
        }
    }

    /// The notes above the left hand's bass: the lowest note (and its octave) goes when it
    /// stands apart below the rest, as a left hand's bass does.
    func upper(_ notes: [Int]) -> [Int] {
        var rest = notes
        for _ in 0..<2 where rest.count >= 2 && rest[0] < 55 && rest[1] - rest[0] >= 5 { rest.removeFirst() }
        return rest.filter { $0 >= 48 }
    }

    mutating func learn(_ notes: [Int], tag: String) -> Key? {
        guard let low = notes.first else { return nil }
        let pcs = notes.reduce(0) { $0 | 1 << mod12($1) }
        guard pcs.nonzeroBitCount >= 3 else { return nil }
        let cacheKey = pcs << 4 | mod12(low)
        if named[cacheKey] == nil { named[cacheKey] = .some(detectChord(notes)) }
        guard let chord = named[cacheKey]!, Set(notes.map(mod12)).isSubset(of: chord.palette(1)) else { return nil }
        let up = upper(notes)
        guard (3...7).contains(up.count), up.last! - up.first! <= 26,
              Set(up.map(mod12)).count >= 3 else { return nil }
        let ref = up[0] - mod12(up[0] - chord.root)
        return Key(q: chord.q.suffix, bass: mod12(chord.bass - chord.root), iv: up.map { $0 - ref }, tag: tag)
    }

    /// The bank: shapes used at least `minimum` times.
    public func bank(minimum: Int = 2) -> VoicingBank {
        let shapes = counts.filter { $0.value.n >= minimum }.map { k, v in
            VoicingBank.Shape(q: k.q, bass: k.bass, iv: k.iv, tag: k.tag, n: v.n, at: Int((Double(v.at) / Double(v.n)).rounded()))
        }.sorted { ($0.q, $0.bass, $0.tag, -$0.n, $0.iv.description) < ($1.q, $1.bass, $1.tag, -$1.n, $1.iv.description) }
        return VoicingBank(shapes: shapes, files: files)
    }
}
