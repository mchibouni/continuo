// Phrases players actually played, learned from MIDI files and played back over your chords.
//
// Mining cuts each part of a file into phrases a few bars long, works out the harmony under
// every half bar from all of the file's pitched parts together, and labels every note by its
// job in that chord: root, 3rd, 5th or 7th, a 9th, 11th or 13th (flat or sharp), or a
// chromatic step into a nearby note. Playing a phrase keeps the player's rhythm, timing,
// dynamics and contour, and puts each note on the same job in the chord you're holding,
// as close as it can to where the player had it.

import Foundation

public enum PhraseRole: String, Codable, CaseIterable { case keys, pad, bass, line }

public struct PhraseNote: Codable {
    public var t: Double     // start, beats from the phrase's start
    public var d: Double     // length, beats
    public var v: Int        // velocity
    public var p: Int        // the note the player played
    public var deg: Int      // its job: 0 root, 1 ninth, 2 third, 3 eleventh, 4 fifth, 5 thirteenth, 6 seventh
    public var alt: Int      // semitones from the job's plain note (♭9 is -1, ♯11 +1); for a step, from the note it leads to
    public var root: Int     // the root (pitch class) of the chord it was played over
    public var to: Int?      // a chromatic step: the index of the note it leads into
}

extension PhraseNote {
    // stored as a short list of whole numbers, times in 480ths of a beat, to keep big banks small
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = Double(try c.decode(Int.self)) / 480
        d = Double(try c.decode(Int.self)) / 480
        v = try c.decode(Int.self); p = try c.decode(Int.self)
        deg = try c.decode(Int.self); alt = try c.decode(Int.self); root = try c.decode(Int.self)
        let x = try c.decode(Int.self)
        to = x < 0 ? nil : x
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(Int((t * 480).rounded())); try c.encode(Int((d * 480).rounded()))
        try c.encode(v); try c.encode(p); try c.encode(deg); try c.encode(alt); try c.encode(root); try c.encode(to ?? -1)
    }
}

public struct Phrase: Codable {
    public var tag: String
    public var role: PhraseRole
    public var song: String      // phrases from one groove or song, to play one after another
    public var section: String   // "verse", "chorus"…, or "" when the file doesn't say
    public var order: Int        // its place in the song: variation × 100 + its 4-bar slice; parts with the same order play together
    public var name: String
    public var tempo: Double
    public var bars: Int
    public var notes: [PhraseNote]
}

public struct PhraseBank: Codable {
    public var phrases: [Phrase]
    public var files: [String: Int]
    var byRole: [PhraseRole: [Int]] = [:]

    enum CodingKeys: String, CodingKey { case phrases, files }

    public init(phrases: [Phrase], files: [String: Int]) {
        (self.phrases, self.files) = (phrases, files)
        index()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrases = try c.decode([Phrase].self, forKey: .phrases)
        files = try c.decode([String: Int].self, forKey: .files)
        index()
    }

    mutating func index() {
        byRole = Dictionary(grouping: phrases.indices) { phrases[$0].role }
    }

    public static func load(_ url: URL) throws -> PhraseBank {
        try JSONDecoder().decode(PhraseBank.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url)
    }

    public var tags: [String] { Array(Set(phrases.map(\.tag))).sorted() }

    /// The phrases for a role from some styles, or from any style when those have none.
    public func candidates(_ role: PhraseRole, tags: Set<String>?) -> [Int] {
        let all = byRole[role] ?? []
        guard let tags else { return all }
        let tagged = all.filter { tags.contains(phrases[$0].tag) }
        return tagged.isEmpty ? all : tagged
    }
}

// MARK: a note's job in a chord

/// The plain interval for a job in a chord: its own 3rd, 5th and 7th, and for the colors the
/// one the chord's tensions or scale have.
func plainInterval(_ c: Chord, _ deg: Int) -> Int {
    let q = c.q
    let scale = Set(q.scale), tensions = Set(q.tensions), tones = Set(q.tones)
    func pick(_ options: [Int]) -> Int? {
        options.first { tones.contains($0) } ?? options.first { tensions.contains($0) } ?? options.first { scale.contains($0) }
    }
    switch deg {
    case 0: return 0
    case 1: return pick([2, 1, 3].filter { $0 != q.tones[0] }) ?? 2
    case 2: return q.tones[0]
    case 3: return pick([5, 6].filter { $0 != c.fifth && $0 != q.tones[0] }) ?? 5
    case 4: return c.fifth
    case 5: return pick([9, 8].filter { $0 != c.fifth }) ?? 9
    default:
        let s = c.seventh % 12
        return s != 0 ? s : (scale.contains(10) ? 10 : 11)
    }
}

/// What an interval above a chord's root is doing there.
func job(_ c: Chord, _ i: Int) -> (deg: Int, alt: Int) {
    let q = c.q, sev = c.seventh % 12
    if i == 0 { return (0, 0) }
    if i == q.tones[0] { return (2, 0) }
    if i == c.fifth { return (4, 0) }
    if sev != 0 && i == sev { return (6, 0) }
    let deg: Int
    switch i {
    case 1, 2: deg = 1
    case 3: deg = q.tones[0] == 4 ? 1 : 2     // a ♯9 on a major or dominant chord
    case 4: deg = 2
    case 5: deg = 3
    case 6: deg = c.fifth == 7 ? 3 : 4        // a ♯11, else a ♭5
    case 7: deg = 4
    case 8: deg = c.fifth == 8 ? 4 : 5
    case 9: deg = 5
    default: deg = 6
    }
    return (deg, mod12(i - plainInterval(c, deg) + 6) - 6)
}

/// The interval for a job in another chord: its plain note, bent the same way when the chord
/// allows it. A plain triad stays plain: a seventh becomes the root, and an 11th on a major
/// triad its fifth.
func interval(_ c: Chord, _ deg: Int, _ alt: Int) -> Int {
    var base = plainInterval(c, deg)
    if c.seventh == 12 {
        if deg == 6 { base = 0 }
        if deg == 3 && c.q.tones[0] == 4 { base = c.fifth }
    }
    let palette = c.palette(1)
    // a job the chord has no note for (a 13th over an altered dominant): the nearest note it has
    if !palette.contains(mod12(c.root + base)) {
        base = (1...6).lazy.flatMap { [base - $0, base + $0] }.first { palette.contains(mod12(c.root + $0)) }.map(mod12) ?? base
    }
    guard alt != 0 else { return base }
    let bent = mod12(base + alt)
    return palette.contains(mod12(c.root + bent)) ? bent : base
}

extension Phrase {
    /// Where note `i` goes over `chord`: the same job, nearest to where the player had it once
    /// the phrase moves to the new root, `offset` semitones up or down.
    func place(_ i: Int, over chord: Chord, offset: Int, depth: Int = 0) -> Int {
        let n = notes[i]
        if let to = n.to, depth < 4 { return place(to, over: chord, offset: offset, depth: depth + 1) + n.alt }
        let want = n.p + offset + mod12(chord.root - n.root + 6) - 6
        let pc = mod12(chord.root + interval(chord, n.deg, n.alt))
        var x = want - mod12(want - pc)
        if want - x > 6 { x += 12 }
        return x
    }

    /// The octave shift that puts the phrase's middle note nearest the middle of a range.
    func offset(for range: ClosedRange<Int>) -> Int {
        let ps = notes.map(\.p).sorted()
        guard !ps.isEmpty else { return 0 }
        let mid = Double(ps[ps.count / 2]), center = Double(range.lowerBound + range.upperBound) / 2
        return 12 * Int(((center - mid) / 12).rounded())
    }
}

// MARK: mining

/// Builds a phrase bank: `add` each file with the style it represents, then `bank`.
public struct PhraseMiner {
    public private(set) var phrases: [Phrase] = []
    var files: [String: Int] = [:]
    var seen: Set<Int> = []
    public private(set) var skippedMeter = 0
    /// Phrases kept per part from one long file, spread through it: a five-minute solo
    /// shouldn't outweigh a whole pack of grooves.
    public var perFile = 8

    public init() {}

    static let drumNames = try! NSRegularExpression(pattern: "kick|clap|snare|hat|ride|crash|perc|drum|tom|shaker|cymbal|rim|conga|bongo|fill|top", options: .caseInsensitive)
    static let fxNames = try! NSRegularExpression(pattern: "fx|atmo|noise|riser|sweep|impact|transition|lifter|vocal|vox|rumble|sub ?drop|byp|reverse", options: .caseInsensitive)
    static let bassNames = try! NSRegularExpression(pattern: "bass|sub|808|reese", options: .caseInsensitive)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Learns the phrases in one file. `section` and `song` come from where the file sits
    /// ("…/MIDTEMPO_GROOVE_95_BPM/VERSE/Variation_02.mid"); each track or channel is a player.
    public mutating func add(_ f: MIDIFile, tag: String, song: String, section: String, name: String, variation: Int = 0) {
        guard f.meter.beats == 4 && f.meter.unit == 4 else { skippedMeter += 1; return }   // odd meters come later
        files[tag, default: 0] += 1
        let total = f.notes.map { $0.beat + $0.beats }.max() ?? 0
        let bars = max(1, Int((total / 4 - 0.05).rounded(.up)))

        // who plays what
        var groups: [(role: PhraseRole, notes: [MIDINote])] = []
        let byPlayer = Dictionary(grouping: f.notes) { $0.track * 16 + $0.channel }
        for key in byPlayer.keys.sorted() {
            let ns = byPlayer[key]!, channel = key % 16, trackName = f.trackNames[key / 16] ?? ""
            if channel == 9 || PhraseMiner.matches(PhraseMiner.drumNames, trackName) || PhraseMiner.matches(PhraseMiner.fxNames, trackName) { continue }
            if let prog = f.programs[channel], prog >= 96 { continue }   // sound effects, ethnic, percussive
            if let role = PhraseMiner.role(ns, name: trackName, program: f.programs[channel]) { groups.append((role, ns)) }
        }
        guard !groups.isEmpty else { return }
        // a lone keyboard part: its left hand's bass line is the bass part's phrase, the rest the keys'
        if groups.count == 1, groups[0].role == .keys || groups[0].role == .pad {
            let low = groups[0].notes.filter { $0.note < 48 }
            if low.count >= 4 {
                groups = [(groups[0].role, groups[0].notes.filter { $0.note >= 48 }), (.bass, low)]
            }
        }
        // a bass plays one note at a time: the lowest of anything struck together
        for g in groups.indices where groups[g].role == .bass {
            let ns = groups[g].notes.sorted { ($0.beat, $0.note) < ($1.beat, $1.note) }
            var kept: [MIDINote] = []
            for n in ns where !(kept.last.map { n.beat - $0.beat < 0.06 } ?? false) { kept.append(n) }
            groups[g].notes = kept
        }

        // the harmony every half bar, from everyone pitched
        let pitched = groups.flatMap(\.notes)
        let bassNotes = groups.filter { $0.role == .bass }.flatMap(\.notes)
        var chords: [Chord?] = []
        var last: Chord? = nil
        for w in 0..<(bars * 2) {
            let a = Double(w) * 2, b = a + 2
            var weight: [Int: Double] = [:]
            for n in pitched where n.beat < b && n.beat + n.beats > a + 0.05 {
                weight[mod12(n.note), default: 0] += min(b, n.beat + n.beats) - max(a, n.beat)
            }
            let low = (bassNotes.isEmpty ? pitched : bassNotes)
                .filter { $0.beat < b - 0.25 && $0.beat + $0.beats > a + 0.05 }.map(\.note).min()
            let top = weight.values.max() ?? 0
            let pcs = weight.filter { $0.value >= max(0.2, top * 0.2) }.keys
            if let low, pcs.count + 1 >= 3 {
                last = detectChord([low] + pcs.map { 60 + mod12($0 - 60) + 12 }) ?? last
            }
            chords.append(last)
        }
        func chord(at beat: Double) -> Chord? {
            let w = min(chords.count - 1, max(0, Int((beat + 0.125) / 2)))
            return chords[w] ?? chords.compactMap { $0 }.first
        }

        for (role, ns) in groups {
            var slices = bars <= 8 ? [(0, bars)] : stride(from: 0, to: bars, by: 4).map { ($0, min(4, bars - $0)) }
            if slices.count > perFile {
                let step = Double(slices.count) / Double(perFile)
                slices = (0..<perFile).map { slices[Int(Double($0) * step)] }
            }
            for (start, length) in slices {
                let order = variation * 100 + start / 4
                let a = Double(start * 4), b = Double((start + length) * 4)
                let part = ns.filter { $0.beat >= a - 0.06 && $0.beat < b - 0.06 }.sorted { ($0.beat, $0.note) < ($1.beat, $1.note) }
                guard part.count >= (role == .bass || role == .line ? 4 : 6) else { continue }
                var notes: [PhraseNote] = []
                for n in part {
                    guard let c = chord(at: n.beat) else { continue }
                    let j = job(c, mod12(n.note - c.root))
                    notes.append(PhraseNote(t: max(0, n.beat - a), d: n.beats, v: n.velocity, p: n.note, deg: j.deg, alt: j.alt, root: c.root, to: nil))
                }
                // chromatic notes lead into a note a step away, soon after
                for i in notes.indices {
                    guard let c = chord(at: notes[i].t + a), !c.palette(1).contains(mod12(notes[i].p)) else { continue }
                    if let k = notes.indices.first(where: { k in
                        k != i && notes[k].t > notes[i].t + 0.01 && notes[k].t - notes[i].t <= 1 && abs(notes[k].p - notes[i].p) <= 2
                            && notes[k].to == nil && c.palette(1).contains(mod12(notes[k].p))
                    }) {
                        notes[i].to = k
                        notes[i].alt = notes[i].p - notes[k].p
                    }
                }
                var h = Hasher()
                h.combine(song); h.combine(role.rawValue)
                for n in notes { h.combine(Int(n.t * 48)); h.combine(n.p) }
                guard seen.insert(h.finalize()).inserted else { continue }   // a loop repeated in the song
                phrases.append(Phrase(tag: tag, role: role, song: song, section: section, order: order,
                                      name: name + (slices.count > 1 ? " bars \(start + 1)-\(start + length)" : ""),
                                      tempo: f.tempo, bars: length, notes: notes))
            }
        }
    }

    /// What a player's notes are: a bass line, keyboard chords, a pad, or a single line.
    static func role(_ ns: [MIDINote], name: String, program: Int?) -> PhraseRole? {
        guard ns.count >= 4 else { return nil }
        let pitches = ns.map(\.note).sorted(), median = pitches[pitches.count / 2]
        var strikes = 0, chordal = 0, i = 0
        let sorted = ns.sorted { $0.beat < $1.beat }
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count && sorted[j].beat - sorted[i].beat < 0.06 { j += 1 }
            strikes += 1
            if Set(sorted[i..<j].map { mod12($0.note) }).count >= 3 { chordal += 1 }
            i = j
        }
        let poly = Double(chordal) / Double(max(1, strikes))
        let meanLength = ns.map(\.beats).reduce(0, +) / Double(ns.count)
        if let program, (32...39).contains(program) { return .bass }
        if matches(bassNames, name) && poly < 0.3 { return .bass }
        if poly >= 0.25 { return meanLength >= 1.5 ? .pad : .keys }
        if median < 50 { return .bass }
        return .line
    }

    public var bank: PhraseBank { PhraseBank(phrases: phrases, files: files) }
}

// MARK: playing phrases

extension Engine {
    /// A part's phrase candidates: its role, from its styles.
    func phraseCandidates(_ p: Part) -> [Int] {
        guard let bank = phraseBank, let setting = p.phrases else { return [] }
        let tags = setting == "any" ? nil : Set(setting.split(separator: ",").map(String.init))
        let c = bank.candidates(p.phraseRole, tags: tags)
        return c.isEmpty && p.phraseRole == .pad ? bank.candidates(.keys, tags: tags) : c
    }

    /// The band's next take: the next one of the song's current section, or a new song, the
    /// one most of the phrase parts can play together, near the band's tempo. Every part the
    /// song has phrases for plays its own from that take, so they interlock as written.
    func advanceBand(_ k: Int) {
        guard let bank = phraseBank else { return }
        let ph = bank.phrases
        let members = parts.indices.filter { parts[$0].phrases != nil && !parts[$0].mute }
        var cands: [Int: [Int]] = [:]
        for i in members { cands[i] = phraseCandidates(parts[i]) }
        // the band's section, or when the song has none by that name, its biggest one
        func inSection(_ list: [Int]) -> [Int] {
            let here = list.filter { ph[$0].section.lowercased() == section }
            if !here.isEmpty || list.isEmpty { return here.isEmpty ? list : here }
            let bySection = Dictionary(grouping: list) { ph[$0].section.lowercased() }
            let biggest = bySection.keys.max { (bySection[$0]!.count, $1) < (bySection[$1]!.count, $0) }!
            return bySection[biggest]!
        }
        func takes(_ song: String) -> [Int] {
            Array(Set(inSection(members.flatMap { cands[$0]!.filter { ph[$0].song == song } }).map { ph[$0].order })).sorted()
        }
        var order: Int? = nil
        if let song = bandSong {
            let list = takes(song)
            // a song of a single take plays twice, then the band moves on
            if !list.isEmpty && (list.count > 1 || bandPlays < 2) { order = list.first { $0 > bandOrder } ?? list.first }
        }
        if order == nil {
            var cover: [String: Int] = [:], tempoOf: [String: Double] = [:]
            for i in members {
                for j in cands[i]! {
                    tempoOf[ph[j].song] = ph[j].tempo
                }
                for song in Set(cands[i]!.map { ph[$0].song }) { cover[song, default: 0] += parts[i].kind == .arp ? 1 : 2 }
            }
            guard let best = cover.values.max() else { bandSong = nil; return }
            let ranked = cover.filter { $0.value == best }.keys
                .sorted { (abs(log(tempo / tempoOf[$0]!)), $0) < (abs(log(tempo / tempoOf[$1]!)), $1) }
                .filter { $0 != bandSong || cover.count == 1 }
            let top = Array(ranked.prefix(8))
            guard !top.isEmpty else { return }
            let seed = parts.first?.seed ?? 1
            bandSong = top[min(top.count - 1, Int(rand(seed, bandSongs, 8) * Double(top.count)))]
            (bandSongs, bandPlays) = (bandSongs + 1, 0)
            order = takes(bandSong!).first
        }
        guard let order, let song = bandSong else { return }
        (bandOrder, bandStep, bandPlays) = (order, k, bandPlays + 1)
        var bars = 0
        for i in members {
            let mine = inSection(cands[i]!.filter { ph[$0].song == song })
            guard let pick = mine.min(by: { (abs(ph[$0].order - order), ph[$0].name) < (abs(ph[$1].order - order), ph[$1].name) })
            else { continue }   // the song has nothing for this part: it picks its own
            startPhrase(i, pick, at: k)
            parts[i].phraseSong = song
            bars = max(bars, ph[pick].bars)
        }
        bandBars = max(1, bars)
        onLog("band: \((song as NSString).lastPathComponent) \(section) take \(order)")
    }

    /// A part's own next phrase, when the band's song has none for it: the next of its own
    /// song, or a new song near the band's tempo.
    func nextPhrase(_ i: Int, at k: Int) {
        let p = parts[i]
        guard let bank = phraseBank else { return }
        let cands = phraseCandidates(p)
        guard !cands.isEmpty else { p.phrase = nil; return }
        let ph = bank.phrases
        func pool(_ song: String) -> [Int] {
            let mine = cands.filter { ph[$0].song == song }
            let here = mine.filter { ph[$0].section.lowercased() == section }
            return (here.isEmpty ? mine : here).sorted { (ph[$0].order, ph[$0].name) < (ph[$1].order, ph[$1].name) }
        }
        var pick: Int? = nil
        if let song = p.phraseSong {
            let list = pool(song)
            if list.count > 1 || p.phrasePlays < 2 {
                if let cur = p.phrase, let j = list.firstIndex(of: cur) { pick = list[(j + 1) % list.count] } else { pick = list.first }
            }
        }
        if pick == nil {
            let songs = Dictionary(grouping: cands) { ph[$0].song }
            let ranked = songs.keys.sorted { a, b in
                (abs(log(tempo / ph[songs[a]![0]].tempo)), a) < (abs(log(tempo / ph[songs[b]![0]].tempo)), b)
            }.filter { $0 != p.phraseSong || songs.count == 1 }
            let top = Array(ranked.prefix(8))
            let song = top[min(top.count - 1, Int(rand(p.seed, p.songsPlayed, 7) * Double(top.count)))]
            (p.songsPlayed, p.phraseSong, p.phrasePlays) = (p.songsPlayed + 1, song, 0)
            pick = pool(song).first
        }
        guard let pick else { p.phrase = nil; return }
        startPhrase(i, pick, at: k)
    }

    func startPhrase(_ i: Int, _ pick: Int, at k: Int) {
        guard let bank = phraseBank else { return }
        let p = parts[i], phrase = bank.phrases[pick]
        if p.phrase != pick { p.phrasePlays += 1 }
        (p.phrase, p.phraseStep, p.phraseOffset) = (pick, k, phrase.offset(for: p.range))
        p.phraseSteps = Dictionary(grouping: phrase.notes.indices) { Int((phrase.notes[$0].t * 4).rounded(.down)) }
        // turning density down drops the softest notes first
        let vs = phrase.notes.map(\.v).sorted()
        p.phraseFloor = p.density >= 0.95 || p.kind == .bass || vs.isEmpty ? 0
            : vs[min(vs.count - 1, Int(Double(vs.count) * (1 - p.density) * 0.8))]
        onLog("\(p.name): \(phrase.name)")
    }

    /// Queues the notes of a part's phrase that start in step `k`, at the player's own timing.
    func schedulePhrase(_ i: Int, _ k: Int) {
        let p = parts[i]
        guard let bank = phraseBank else { return }
        let banded = p.phraseSong != nil && p.phraseSong == bandSong
        if let cur = p.phrase, k >= p.phraseStep + bank.phrases[cur].bars * stepsPerBar {
            if banded { startPhrase(i, cur, at: k) } else { nextPhrase(i, at: k) }   // a short take repeats until the band moves on
        }
        if p.phrase == nil {
            guard k % stepsPerBar == 0 else { return }   // phrases start on a bar
            nextPhrase(i, at: k)
        }
        guard let cur = p.phrase else { return }
        let phrase = bank.phrases[cur], step = k - p.phraseStep
        for j in p.phraseSteps[step] ?? [] where phrase.notes[j].v >= p.phraseFloor {
            let due = stepTime(k) + (phrase.notes[j].t * 4 - Double(step)) * stepDuration
            heap.push(due, .phrase(part: i, phrase: cur, note: j, due: due))
        }
    }

    /// A phrase note over the chord being held, folded into the part's range. A bass lands on
    /// the chord's own bass note with its first note after a change, as a bass player does.
    func placed(_ p: Part, _ phrase: Phrase, _ j: Int, _ chord: Chord, landing: Bool = false) -> Int? {
        var n = phrase.place(j, over: chord, offset: p.phraseOffset)
        if landing {
            n += mod12(chord.bass - n + 6) - 6
        } else if p.kind == .bass && [1, 3, 5].contains(phrase.notes[j].deg) && phrase.notes[j].d > 0.5 && phrase.notes[j].to == nil {
            // a 9th, 11th or 13th held in a bass line sounds like a wrong note over another chord: the nearest chord tone
            let tones = chord.core
            n = tones.map { n + mod12(chord.root + $0 - n + 6) - 6 }.min { abs($0 - n) < abs($1 - n) } ?? n
        }
        let r = p.range
        while n < r.lowerBound { n += 12 }
        while n > r.upperBound { n -= 12 }
        return r.contains(n) ? n : nil
    }

    func firePhrase(_ i: Int, _ cur: Int, _ j: Int, at t: Double) {
        let p = parts[i]
        guard !p.mute, gated, let chord, let bank = phraseBank else { return }
        let phrase = bank.phrases[cur], src = phrase.notes[j]
        let landing = p.kind == .bass && p.landed != chord
        guard let note = placed(p, phrase, j, chord, landing: landing) else { return }
        if p.kind == .bass { p.landed = chord }
        p.sounding.removeAll { $0.off <= t + 1e-9 || active[$0.key]?.token != $0.token }
        let k = key(p, note)
        if p.sounding.contains(where: { $0.key == k && t - $0.on < 0.03 }) { return }   // two notes of one chord landed together
        if p.mono {
            for s in p.sounding {
                if p.legato { heap.push(t + 0.003, .off(key: s.key, token: s.token, part: i)) } else { endNote(s.key, s.token, at: t, part: i) }
            }
            p.sounding = []
        }
        let velocity = p.velLo + (max(1, src.v) - 1) * (p.velHi - p.velLo) / 126
        let off = t + max(0.03, src.d * 60 / tempo)
        let token = startNote(i, note, velocity, at: t, until: off)
        p.sounding.append((k, token, cur, j, t, off, velocity))
        p.lastNote = note
    }

    /// Whether the part's phrase has a note starting within `within` seconds after `t`.
    func phraseNoteSoon(_ p: Part, _ phrase: Phrase, after t: Double, within: Double) -> Bool {
        let beat = (t - stepTime(p.phraseStep)) / stepDuration / 4, span = within / stepDuration / 4
        return phrase.notes.contains { $0.t >= beat - 0.02 && $0.t <= beat + span }
    }

    /// A chord change under a phrase: what's still sounding moves to its place in the new chord.
    func rephrase(_ i: Int, at t: Double) {
        let p = parts[i]
        guard !p.mute, let chord, let bank = phraseBank else { return }
        if p.kind == .bass {
            // a bass plays again on a change: what it holds ends, and unless its line has a note
            // coming right away, it lands the new chord's bass note for the rest of that note
            var held = p.sounding.filter { $0.off > t + 0.05 && active[$0.key]?.token == $0.token }
            guard !held.isEmpty else { return }
            for s in held { endNote(s.key, s.token, at: t, part: i) }
            p.sounding.removeAll { s in held.contains { $0.token == s.token } }
            if let cur = p.phrase, !phraseNoteSoon(p, bank.phrases[cur], after: t, within: 0.15), let s = held.popLast(),
               let note = placed(p, bank.phrases[s.phrase], s.note, chord, landing: true) {
                let token = startNote(i, note, s.velocity, at: t, until: s.off)
                p.sounding.append((key(p, note), token, s.phrase, s.note, t, s.off, s.velocity))
                p.landed = chord
            }
            corrections += 1
            return
        }
        var moved = false
        for (x, s) in p.sounding.enumerated() where s.off > t + 0.05 && active[s.key]?.token == s.token {
            let landing = p.kind == .bass
            if landing { p.landed = chord }
            guard let note = placed(p, bank.phrases[s.phrase], s.note, chord, landing: landing), key(p, note) != s.key else { continue }
            endNote(s.key, s.token, at: t, part: i)
            let token = startNote(i, note, s.velocity, at: t, until: s.off)
            p.sounding[x] = (key(p, note), token, s.phrase, s.note, t, s.off, s.velocity)
            moved = true
        }
        if moved { corrections += 1 }
    }
}
