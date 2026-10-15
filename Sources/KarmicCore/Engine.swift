// The band. It keeps a sixteenth-note grid, asks each part's style which steps to play, and
// works out the notes of a hit only when the hit is due, so a chord change reaches every part
// on the next step. Times are seconds on the caller's clock (host time live, 0-based when
// rehearsing); every message goes out stamped with the exact time it belongs to.
//
// Following the player's chord changes:
//   - a chord's notes never arrive together, so the chord is named `settle` after its last
//     note-on (notes coming up never change it: lifting a finger is not a new chord)
//   - a hit that falls due while a chord is still arriving waits for it (at most 60 ms), so
//     playing on the beat gives the new chord on the beat, a hair late, never the old one
//   - a change that comes after a hit has started re-voices the notes still sounding, keeping
//     the notes the two chords share: always for retrigger parts (bass, keys), and within
//     80 ms of the hit for the others, which catches a chord played a little late

import Foundation

public protocol Sink: AnyObject {
    /// One MIDI message for an output, at an absolute time; `part` is -1 for clock messages.
    func send(_ bytes: [UInt8], output: Int, at time: Double, part: Int)
}

struct Hit {
    var on: Double, off: Double
    var notes: [Int], keys: [Int], tokens: [Int]
    var velocity: Int
    var role: Character
    var step: Int
    var before: Int?          // the part's last note before this hit
    var voicingBefore: [Int]
    var index: Int            // the arp position it played
}

public final class Part {
    public let name: String
    public let kind: Kind
    let spec: PartSpec        // as configured: scenes start again from it
    public internal(set) var style: Style
    public internal(set) var output = 0, channel = 0, lo = 0, hi = 127
    public internal(set) var density = 0.75, complexity = 0.5, accent = 0.5, vary = 0.0, humanize = 4.0
    public internal(set) var gate: Double? = nil, swing: Double? = nil, feel: Int? = nil
    public internal(set) var velLo = 60, velHi = 105, voices = 4, span = 2, octave = 0, loop = 2
    public internal(set) var seed: UInt64 = 1
    public internal(set) var mute = false, mono = false, legato = false, retrigger = true, rootless = false
    public internal(set) var program: Int? = nil

    var counter = 0, loopIndex = -1
    var lastNote: Int? = nil
    var voicing: [Int] = []
    var walkUp = true
    var last: Hit? = nil

    init(_ spec: PartSpec, name: String, kind: Kind) {
        (self.spec, self.name, self.kind) = (spec, name, kind)
        style = styles.first { $0.kind == kind }!
        reset()
    }

    /// The defaults for its kind, before the config and a scene say otherwise.
    func reset() {
        style = styles.first { $0.kind == kind }!
        density = 0.75; accent = 0.5; vary = 0; humanize = 4; gate = nil; swing = nil; feel = nil
        octave = 0; loop = 2; mute = false; legato = false; program = nil
        seed = name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        switch kind {
        case .bass:
            (lo, hi, velLo, velHi, complexity) = (28, 52, 70, 112, 0.5)
            (mono, retrigger, rootless) = (true, true, false)
        case .comp:
            (lo, hi, velLo, velHi, complexity, voices) = (52, 79, 55, 100, 0.6, 4)
            (mono, retrigger, rootless) = (false, true, true)
        case .arp:
            (lo, hi, velLo, velHi, complexity, span, density) = (60, 96, 50, 95, 0.5, 2, 0.8)
            (mono, retrigger, rootless) = (false, false, false)
        }
    }

    public var range: ClosedRange<Int> { max(0, lo + 12 * octave)...min(127, hi + 12 * octave) }
}

enum Action {
    case hit(part: Int, onset: Onset, step: Int, due: Double)
    case off(key: Int, token: Int, part: Int)
    case raw(bytes: [UInt8], output: Int)
}

struct EventHeap {
    struct Event { let time: Double; let seq: Int; let action: Action }
    private var items: [Event] = []
    private var seq = 0

    var peekTime: Double? { items.first?.time }

    mutating func push(_ time: Double, _ action: Action) {
        seq += 1
        items.append(Event(time: time, seq: seq, action: action))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(items[i], items[parent]) else { break }
            items.swapAt(i, parent); i = parent
        }
    }

    mutating func pop() -> Event? {
        guard !items.isEmpty else { return nil }
        let top = items[0], last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && less(items[l], items[m]) { m = l }
                if r < items.count && less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m); i = m
            }
        }
        return top
    }

    mutating func removeAll() { items.removeAll() }

    private func less(_ a: Event, _ b: Event) -> Bool { a.time < b.time || (a.time == b.time && a.seq < b.seq) }
}

/// Repeatable dice: the same seed, step and salt always roll the same number in [0, 1).
func rand(_ seed: UInt64, _ k: Int, _ salt: UInt64) -> Double {
    var z = seed &+ UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xD1B5_4A32_D192_ED03
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / 9_007_199_254_740_992
}

func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.2f", x) }

public final class Engine {
    public let sink: Sink
    public private(set) var parts: [Part] = []
    public private(set) var outputNames: [String] = []
    public private(set) var inputs: [InputSpec] = []
    public private(set) var scenes: [Scene] = []
    public private(set) var scene: String? = nil
    var clockOutputs: [Int] = []
    let config: Config
    public var onLog: (String) -> Void = { _ in }
    public var onChord: (Double, Chord) -> Void = { _, _ in }

    public private(set) var tempo = 100.0, swing = 50.0, feel = 16, stepsPerBar = 16
    var latch = true, autoStart = true, settle = 0.015
    let catchWindow = 0.08, maxWait = 0.06, margin = 0.008

    var held: [Int: Set<Int>] = [:]
    public private(set) var chord: Chord? = nil
    var evalAt: Double? = nil
    var gated = true

    public private(set) var running = false
    var anchorTime = 0.0, anchorStep = 0
    public private(set) var nextStep = 0
    var heap = EventHeap()
    var active: [Int: (token: Int, part: Int)] = [:]   // what each key is sounding, by output/channel/note
    var tokens = 0
    public private(set) var corrections = 0   // hits re-voiced because the chord changed under them

    public init(config: Config, sink: Sink) throws {
        self.config = config
        self.sink = sink
        outputNames = (config.outputs ?? [OutputSpec(name: "karmic", port: "virtual")]).map(\.name)
        inputs = config.inputs ?? []
        tempo = min(300, max(20, config.tempo ?? 100))
        swing = min(75, max(50, config.swing ?? 50))
        feel = config.feel == 8 ? 8 : 16
        stepsPerBar = max(1, config.stepsPerBar ?? 16)
        latch = config.latch ?? true
        autoStart = config.autoStart ?? true
        settle = max(0, config.settle ?? 15) / 1000
        clockOutputs = try (config.clockOut ?? []).map(outputIndex)
        for spec in config.parts {
            guard let name = spec.name, let kind = spec.kind else { throw ConfigError("every part needs a name and a kind (bass, comp or arp)") }
            guard part(name) == nil else { throw ConfigError("two parts are called \(name)") }
            let p = Part(spec, name: name, kind: kind)
            try apply(spec, to: p)
            parts.append(p)
        }
        scenes = config.scenes ?? []
        for s in scenes {
            for (name, spec) in s.parts ?? [:] {
                guard let p = part(name) else { throw ConfigError("scene \(s.name) names no part called \(name)") }
                try apply(spec, to: Part(p.spec, name: p.name, kind: p.kind))   // check it on a copy
            }
        }
        if let s = config.startScene { try applyScene(s, at: 0) }
    }

    public func part(_ name: String) -> Part? { parts.first { $0.name == name } }

    func outputIndex(_ name: String) throws -> Int {
        guard let i = outputNames.firstIndex(of: name) else { throw ConfigError("no output called \(name)") }
        return i
    }

    func apply(_ s: PartSpec, to p: Part) throws {
        func unit(_ v: Double?, _ set: (Double) -> Void) { if let v { set(min(1, max(0, v))) } }
        if let v = s.style {
            guard let st = style(named: v, kind: p.kind) else {
                throw ConfigError("\(p.name): no \(p.kind) style called \(v) (\(styles.filter { $0.kind == p.kind }.map(\.name).joined(separator: ", ")))")
            }
            p.style = st
        }
        if let v = s.out { p.output = try outputIndex(v) }
        if let v = s.channel {
            guard (1...16).contains(v) else { throw ConfigError("\(p.name): channel \(v) is not 1-16") }
            p.channel = v - 1
        }
        if let v = s.range {
            guard v.count == 2, v[0] < v[1], v.allSatisfy({ (0...127).contains($0) }) else { throw ConfigError("\(p.name): range needs a low and a high note, 0-127") }
            (p.lo, p.hi) = (v[0], v[1])
        }
        if let v = s.velocity {
            guard v.count == 2, v[0] <= v[1], v.allSatisfy({ (1...127).contains($0) }) else { throw ConfigError("\(p.name): velocity needs a softest and a loudest, 1-127") }
            (p.velLo, p.velHi) = (v[0], v[1])
        }
        unit(s.density) { p.density = $0 }
        unit(s.complexity) { p.complexity = $0 }
        unit(s.accent) { p.accent = $0 }
        unit(s.vary) { p.vary = $0 }
        if let v = s.gate { p.gate = min(1.5, max(0.05, v)) }
        if let v = s.swing { p.swing = min(75, max(50, v)) }
        if let v = s.feel { p.feel = v == 8 ? 8 : 16 }
        if let v = s.voices { p.voices = min(6, max(1, v)) }
        if let v = s.span { p.span = min(4, max(1, v)) }
        if let v = s.octave { p.octave = min(3, max(-3, v)) }
        if let v = s.loop { p.loop = min(16, max(1, v)) }
        if let v = s.humanize { p.humanize = min(30, max(0, v)) }
        if let v = s.seed { p.seed = UInt64(bitPattern: Int64(v)) }
        if let v = s.mute { p.mute = v }
        if let v = s.mono { p.mono = v }
        if let v = s.legato { p.legato = v }
        if let v = s.retrigger { p.retrigger = v }
        if let v = s.rootless { p.rootless = v }
        if let v = s.program {
            guard (1...128).contains(v) else { throw ConfigError("\(p.name): program \(v) is not 1-128") }
            p.program = v
        }
    }

    /// Changes a part, ending what it plays if it moves channel or output or goes quiet.
    func change(_ i: Int, at t: Double, _ body: () throws -> Void) rethrows {
        let p = parts[i], before = (p.output, p.channel, p.mute, p.style.name), program = p.program
        try body()
        if before != (p.output, p.channel, p.mute, p.style.name) { endPart(i, at: t) }
        if before.3 != p.style.name { p.counter = 0; p.loopIndex = -1 }
        if running && (program != p.program || before.0 != p.output || before.1 != p.channel) { sendProgram(i, at: t) }
    }

    func applyScene(_ name: String, at t: Double) throws {
        let found = scenes.first { $0.name == name } ?? Int(name).flatMap { (1...scenes.count).contains($0) ? scenes[$0 - 1] : nil }
        guard let s = found else { throw ConfigError("no scene \(name) (\(scenes.map(\.name).joined(separator: ", ")))") }
        for (i, p) in parts.enumerated() {
            try change(i, at: t) {
                p.reset()
                try apply(p.spec, to: p)
                if let o = s.parts?[p.name] { try apply(o, to: p) }
            }
        }
        setTempo(s.tempo ?? config.tempo ?? tempo, at: t)
        swing = min(75, max(50, s.swing ?? config.swing ?? 50))
        feel = (s.feel ?? config.feel) == 8 ? 8 : 16
        scene = s.name
    }

    // MARK: time

    public var stepDuration: Double { 60 / tempo / 4 }
    public func stepTime(_ k: Int) -> Double { anchorTime + Double(k - anchorStep) * stepDuration }

    func setTempo(_ bpm: Double, at t: Double) {
        if running { (anchorTime, anchorStep) = (stepTime(nextStep), nextStep) }
        tempo = min(300, max(20, bpm))
    }

    /// When the engine next has something to do.
    public func nextWake() -> Double {
        min(heap.peekTime ?? .infinity, running ? stepTime(nextStep) - margin : .infinity, evalAt ?? .infinity)
    }

    /// Does everything due up to `t`, in time order.
    public func run(until t: Double) {
        while true {
            let a = heap.peekTime ?? .infinity
            let b = running ? stepTime(nextStep) - margin : .infinity
            let c = evalAt ?? .infinity
            let m = min(a, b, c)
            if m > t { return }
            if c == m {
                evalAt = nil
                evaluate(at: c)
            } else if b == m {
                schedule(nextStep)
                nextStep += 1
            } else if let e = heap.pop() {
                handle(e)
            }
        }
    }

    func handle(_ e: EventHeap.Event) {
        switch e.action {
        case let .hit(i, onset, k, due):
            if let ev = evalAt, ev > e.time, e.time - due < maxWait - 1e-9 {
                heap.push(min(ev, due + maxWait), e.action)   // a chord is still arriving
                return
            }
            fire(i, onset, k, at: e.time)
        case let .off(key, token, i):
            endNote(key, token, at: e.time, part: i)
        case let .raw(bytes, output):
            sink.send(bytes, output: output, at: e.time, part: -1)
        }
    }

    func schedule(_ k: Int) {
        let t0 = stepTime(k)
        for (i, p) in parts.enumerated() where !p.mute {
            guard let on = p.style.onsets[k % p.style.steps] else { continue }
            var w = Double(on.weight)
            if p.vary > 0 { w += (rand(p.seed, k % (p.loop * stepsPerBar), 1) - 0.5) * 4 * p.vary }
            guard w >= 9 - p.density * 8 - 1e-9 else { continue }
            let t = t0 + swingOffset(k, p) + (rand(p.seed, k, 2) - 0.5) * 2 * p.humanize / 1000
            heap.push(t, .hit(part: i, onset: on, step: k, due: t))
        }
        for o in clockOutputs {
            for j in 0..<6 { heap.push(t0 + Double(j) * stepDuration / 6, .raw(bytes: [0xF8], output: o)) }
        }
    }

    func swingOffset(_ k: Int, _ p: Part) -> Double {
        let o = 2 * (p.swing ?? swing) / 100 - 1
        if (p.feel ?? feel) == 8 { return k % 4 == 2 ? 2 * o * stepDuration : k % 4 == 3 ? o * stepDuration : 0 }
        return k % 2 == 1 ? o * stepDuration : 0
    }

    // MARK: notes

    func key(_ p: Part, _ note: Int) -> Int { p.output * 2048 + p.channel * 128 + note }

    func sendOff(_ key: Int, at t: Double, part: Int) {
        sink.send([0x80 | UInt8(key / 128 % 16), UInt8(key % 128), 0], output: key / 2048, at: t, part: part)
    }

    func startNote(_ i: Int, _ note: Int, _ velocity: Int, at t: Double, until off: Double) -> Int {
        let p = parts[i], k = key(p, note)
        if let a = active[k] { sendOff(k, at: t, part: a.part) }   // the synth must hear it end first
        tokens += 1
        active[k] = (tokens, i)
        sink.send([0x90 | UInt8(p.channel), UInt8(note), UInt8(velocity)], output: p.output, at: t, part: i)
        heap.push(off, .off(key: k, token: tokens, part: i))
        return tokens
    }

    func endNote(_ key: Int, _ token: Int, at t: Double, part: Int) {
        guard active[key]?.token == token else { return }   // already ended, or replaced
        sendOff(key, at: t, part: part)
        active[key] = nil
    }

    func endPart(_ i: Int, at t: Double) {
        for k in active.keys.sorted() where active[k]!.part == i {
            sendOff(k, at: t, part: i)
            active[k] = nil
        }
        parts[i].last = nil
    }

    func fire(_ i: Int, _ on: Onset, _ k: Int, at t: Double) {
        let p = parts[i]
        guard !p.mute, gated, let chord else { return }
        let loopSteps = p.loop * stepsPerBar
        if k / loopSteps != p.loopIndex { (p.loopIndex, p.counter) = (k / loopSteps, 0) }
        let before = p.lastNote, voicingBefore = p.voicing, index = p.counter
        if p.kind == .arp { p.counter += 1 }
        let notes = render(p, on.role, chord, k, index: index, prev: before, previous: voicingBefore)
        guard !notes.isEmpty else { return }
        let velocity = self.velocity(p, on, k)
        let gate = on.role == "G" ? min(0.3, p.gate ?? p.style.gate) : (p.gate ?? p.style.gate)
        let off = t + max(0.01, (Double(on.length - 1) + gate) * stepDuration)
        if p.mono, let last = p.last {
            for j in last.notes.indices where !notes.contains(last.notes[j]) {
                if p.legato { heap.push(t + 0.003, .off(key: last.keys[j], token: last.tokens[j], part: i)) }
                else { endNote(last.keys[j], last.tokens[j], at: t, part: i) }
            }
        }
        var keys: [Int] = [], toks: [Int] = []
        for n in notes {
            toks.append(startNote(i, n, velocity, at: t, until: off))
            keys.append(key(p, n))
        }
        p.last = Hit(on: t, off: off, notes: notes, keys: keys, tokens: toks, velocity: velocity, role: on.role,
                     step: k, before: before, voicingBefore: voicingBefore, index: index)
    }

    /// Re-voices what a part is still holding for a chord that changed under it.
    func rerender(_ i: Int, at t: Double) {
        let p = parts[i]
        guard !p.mute, var last = p.last, let chord, last.off > t + 0.02,
              p.retrigger || t - last.on < catchWindow else { return }
        let notes = render(p, last.role, chord, last.step, index: last.index, prev: last.before, previous: last.voicingBefore)
        for j in last.notes.indices where !notes.contains(last.notes[j]) { endNote(last.keys[j], last.tokens[j], at: t, part: i) }
        var keys: [Int] = [], toks: [Int] = []
        for n in notes {
            if let j = last.notes.firstIndex(of: n), active[last.keys[j]]?.token == last.tokens[j] {
                keys.append(last.keys[j]); toks.append(last.tokens[j])   // a shared note keeps sounding
            } else {
                toks.append(startNote(i, n, last.velocity, at: t, until: last.off)); keys.append(key(p, n))
            }
        }
        if notes != last.notes { corrections += 1 }
        (last.notes, last.keys, last.tokens) = (notes, keys, toks)
        p.last = last
    }

    func velocity(_ p: Part, _ on: Onset, _ k: Int) -> Int {
        var v = Double(p.velLo) + Double(p.velHi - p.velLo) * (1 - p.accent * (1 - Double(on.weight) / 9))
        if on.role == "G" { v = Double(p.velLo) * 0.7 }
        v += (rand(p.seed, k, 6) - 0.5) * 8 * min(1, p.humanize / 4)
        return Int(min(127, max(1, v.rounded())))
    }

    func render(_ p: Part, _ role: Character, _ chord: Chord, _ k: Int, index: Int, prev: Int?, previous: [Int]) -> [Int] {
        switch p.kind {
        case .bass:
            guard let n = bassNote(p, role, chord, prev, k) else { return [] }
            p.lastNote = n
            return [n]
        case .comp:
            let full = voice(chord, voices: p.voices, lo: p.range.lowerBound, hi: p.range.upperBound,
                             complexity: p.complexity, rootless: p.rootless, previous: previous)
            p.voicing = full
            switch role {
            case "T": return Array(full.suffix(max(2, (full.count + 1) / 2)))
            case "B": return Array(full.prefix(2))
            case "S":
                let shell = Set(chord.q.tones.prefix(2).map { mod12(chord.root + $0) })
                let s = full.filter { shell.contains(mod12($0)) }
                return s.count >= 2 ? s : Array(full.suffix(2))
            default: return full
            }
        case .arp:
            // from the chord's root up, so an up pattern starts where the chord does
            let r = p.range, bottom = r.lowerBound + mod12(chord.root - r.lowerBound)
            let top = min(r.upperBound, bottom + 12 * p.span)
            let pcs = chord.palette(p.complexity)
            let pool = (min(bottom, top)...top).filter { pcs.contains(mod12($0)) }
            guard !pool.isEmpty else { return [] }
            let j = p.style.order == .random
                ? Int(rand(p.seed, k % (p.loop * stepsPerBar), 3) * Double(pool.count))
                : p.style.order.index(index, pool.count)
            p.lastNote = pool[j]
            return [pool[j]]
        }
    }

    static let roleLevel: [Character: Double] = ["O": 0.15, "5": 0.3, "G": 0.4, "A": 0.5, "S": 0.6, "3": 0.65, "7": 0.65, "T": 0.85]

    func bassNote(_ p: Part, _ role: Character, _ chord: Chord, _ prev: Int?, _ k: Int) -> Int? {
        let r = p.range, lo = r.lowerBound, hi = r.upperBound
        let root = lo + mod12(chord.bass - lo)
        func fit(_ n: Int) -> Int { var n = n; while n > hi { n -= 12 }; while n < lo { n += 12 }; return n }
        func above(_ interval: Int) -> Int { fit(root + mod12(chord.root + interval - chord.bass)) }
        // the root (bass note) nearest to where the line is, to lead into
        func target(_ from: Int) -> Int { [root, root + 12].filter { $0 <= hi }.min { abs($0 - from) < abs($1 - from) } ?? root }
        var role = role
        if let level = Engine.roleLevel[role], level > p.complexity + 1e-9 {
            if role == "G" { return nil }
            role = "R"
        }
        switch role {
        case "L": return root - 12 >= lo ? root - 12 : root
        case "O": return root + 12 <= hi ? root + 12 : root
        case "5": return above(chord.fifth)
        case "3": return above(chord.q.tones[0])
        case "7": return above(chord.seventh % 12)
        case "T": return fit(above(2) + 12)
        case "G": return prev ?? root
        case "A":
            let from = prev ?? root, t = target(from)
            let a = from > t ? t + 1 : t - 1
            return r.contains(a) ? a : (a < lo ? t + 1 : t - 1)
        case "S":
            let from = prev ?? root, t = target(from), scale = Set(chord.scale)
            var s = t + 1
            while !scale.contains(mod12(s)) { s += 1 }
            if s > hi { s = t - 1; while !scale.contains(mod12(s)) { s -= 1 } }
            return s
        case "W":
            let from = prev ?? root
            let pcs = p.complexity >= 0.6 ? Set(chord.tones + chord.scale) : Set(chord.tones)
            for _ in 0..<2 {
                let steps = (1...5).map { from + (p.walkUp ? $0 : -$0) }.filter { r.contains($0) && pcs.contains(mod12($0)) }
                if !steps.isEmpty { return steps.count > 1 && rand(p.seed, k, 5) < 0.35 ? steps[1] : steps[0] }
                p.walkUp.toggle()
            }
            return root
        default:
            p.walkUp = root + 7 <= hi ? rand(p.seed, k, 4) < 0.75 : false   // where a walking line heads next
            return root
        }
    }

    // MARK: the player

    public func noteOn(_ note: Int, channel: Int, input: Int, at t: Double) {
        guard accepts(note, channel, input) else { return }
        held[input, default: []].insert(note)
        evalAt = t + settle
    }

    public func noteOff(_ note: Int, channel: Int, input: Int, at t: Double) {
        guard accepts(note, channel, input) else { return }
        held[input]?.remove(note)
        if !latch && held.values.allSatisfy({ $0.isEmpty }) {
            evalAt = nil
            gated = false
            for i in parts.indices { endPart(i, at: t) }
        }
    }

    func accepts(_ note: Int, _ channel: Int, _ input: Int) -> Bool {
        guard inputs.indices.contains(input) else { return false }
        let s = inputs[input]
        if let c = s.channel, c - 1 != channel { return false }
        if let z = s.zone, z.count == 2, !(z[0]...z[1]).contains(note) { return false }
        return true
    }

    func evaluate(at t: Double) {
        guard let c = detectChord(held.values.flatMap { $0 }) else { return }
        gated = true
        setChord(c, at: t)
    }

    func setChord(_ c: Chord, at t: Double) {
        guard c != chord else { return }
        chord = c
        onChord(t, c)
        onLog("chord \(c)")
        if !running {
            if autoStart { start(at: t) }
            return
        }
        for i in parts.indices { rerender(i, at: t) }
    }

    // MARK: transport

    public func start(at t: Double) {
        guard !running else { return }
        running = true
        (anchorTime, anchorStep, nextStep) = (t, 0, 0)
        for p in parts { (p.counter, p.loopIndex, p.last, p.lastNote, p.voicing) = (0, -1, nil, nil, []) }
        for i in parts.indices { sendProgram(i, at: t) }
        for o in clockOutputs { sink.send([0xFA], output: o, at: t, part: -1) }
        onLog("start, \(fmt(tempo)) BPM")
    }

    func sendProgram(_ i: Int, at t: Double) {
        let p = parts[i]
        if let program = p.program { sink.send([0xC0 | UInt8(p.channel), UInt8(program - 1)], output: p.output, at: t, part: i) }
    }

    public func stop(at t: Double) {
        let was = running
        running = false
        heap.removeAll()
        for k in active.keys.sorted() { sendOff(k, at: t, part: active[k]!.part) }
        active.removeAll()
        for p in parts { p.last = nil }
        if was {
            for o in clockOutputs { sink.send([0xFC], output: o, at: t, part: -1) }
            onLog("stop")
        }
    }

    func panic(at t: Double) {
        stop(at: t)
        var seen = Set<Int>()
        for p in parts where seen.insert(p.output * 16 + p.channel).inserted {
            sink.send([0xB0 | UInt8(p.channel), 123, 0], output: p.output, at: t, part: -1)   // all notes off
        }
    }

    // MARK: commands

    /// One line of the control protocol (see `karmic help`); returns the reply.
    public func control(_ line: String, at t: Double) -> String {
        let w = line.split(separator: " ").map(String.init)
        guard let cmd = w.first?.lowercased() else { return status() }
        do {
            switch cmd {
            case "start": start(at: t); return chord == nil ? "started, waiting for a chord" : "started"
            case "stop": stop(at: t); return "stopped"
            case "panic": panic(at: t); return "all notes off"
            case "tempo":
                guard w.count == 2, let v = Double(w[1]) else { throw ConfigError("tempo <bpm>") }
                setTempo(v, at: t); return "tempo \(fmt(tempo))"
            case "swing":
                guard w.count == 2, let v = Double(w[1]), (50...75).contains(v) else { throw ConfigError("swing <50-75>") }
                swing = v; return "swing \(fmt(swing))"
            case "feel":
                guard w.count == 2, let v = Int(w[1]), v == 8 || v == 16 else { throw ConfigError("feel <8|16>") }
                feel = v; return "swing on \(v == 8 ? "eighths" : "sixteenths")"
            case "chord":
                guard let c = parseChord(w.dropFirst().joined()) else { throw ConfigError("chord <symbol>, e.g. chord Dm9") }
                gated = true
                setChord(c, at: t); return "chord \(c)"
            case "scene":
                guard w.count == 2 else { return "scenes: " + scenes.enumerated().map { "\($0.offset + 1) \($0.element.name)" }.joined(separator: ", ") }
                try applyScene(w[1], at: t); return "scene \(scene!)"
            case "set":
                let path = w.count >= 3 ? w[1].split(separator: ".").map(String.init) : []
                guard path.count == 2, let i = parts.firstIndex(where: { $0.name == path[0] }) else {
                    throw ConfigError("set <part>.<setting> <value>, parts: \(parts.map(\.name).joined(separator: ", "))")
                }
                let spec = try Engine.spec(path[1], Array(w.dropFirst(2)))
                try change(i, at: t) { try apply(spec, to: parts[i]) }
                return describe(parts[i])
            case "mute", "unmute", "toggle":
                let names = w.count == 1 || w[1] == "all" ? parts.map(\.name) : Array(w.dropFirst())
                for n in names {
                    guard let i = parts.firstIndex(where: { $0.name == n }) else { throw ConfigError("no part called \(n)") }
                    change(i, at: t) { parts[i].mute = cmd == "mute" ? true : cmd == "unmute" ? false : !parts[i].mute }
                }
                return parts.filter { names.contains($0.name) }.map(describe).joined(separator: "\n")
            case "status": return status()
            default: throw ConfigError("unknown command \(cmd)")
            }
        } catch {
            return "error: \(error)"
        }
    }

    /// A part setting from text, through the config's own decoder, so the names and types are
    /// the config file's.
    static func spec(_ key: String, _ values: [String]) throws -> PartSpec {
        func value(_ s: String) -> Any {
            if let i = Int(s) { return i }
            if let d = Double(s) { return d }
            return s == "true" ? true : s == "false" ? false : s as Any
        }
        guard !values.isEmpty else { throw ConfigError("set needs a value") }
        let data = try JSONSerialization.data(withJSONObject: [key: values.count == 1 ? value(values[0]) : values.map(value)])
        let spec: PartSpec
        do { spec = try JSONDecoder().decode(PartSpec.self, from: data) } catch { throw ConfigError("\(key) can't be \(values.joined(separator: " "))") }
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any]
        guard back?[key] != nil, key != "name", key != "kind" else { throw ConfigError("no setting called \(key)") }
        return spec
    }

    public func describe(_ p: Part) -> String {
        let r = p.range
        var s = "\(p.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.style.name.padding(toLength: 10, withPad: " ", startingAt: 0))"
        s += " ch\(p.channel + 1) → \(outputNames[p.output])  density \(fmt(p.density)) complexity \(fmt(p.complexity))"
        s += "  \(noteName(r.lowerBound))-\(noteName(r.upperBound))"
        if p.kind == .comp { s += " \(p.voices) voices" }
        if p.vary > 0 { s += " vary \(fmt(p.vary))" }
        return s + (p.mute ? "  (muted)" : "")
    }

    public func status() -> String {
        var s = running ? "playing" : "stopped"
        s += " · \(fmt(tempo)) BPM · swing \(fmt(swing)) on \(feel == 8 ? "eighths" : "sixteenths")"
        if running { s += " · bar \(nextStep / stepsPerBar + 1)" }
        s += " · chord \(chord?.description ?? "none")"
        if let scene { s += " · scene \(scene)" }
        return ([s] + parts.map(describe)).joined(separator: "\n")
    }
}
