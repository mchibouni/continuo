// Rehearsing without sound: a chord progression played into an engine on a simulated clock,
// everything it sends recorded, then printed bar by bar, checked, and written as a MIDI file.

import Foundation

public final class Recorder: Sink {
    public struct Message {
        public let time: Double
        public let output: Int
        public let part: Int
        public let bytes: [UInt8]
    }
    public private(set) var messages: [Message] = []
    public init() {}
    public func send(_ bytes: [UInt8], output: Int, at time: Double, part: Int) {
        messages.append(Message(time: time, output: output, part: part, bytes: bytes))
    }
}

public struct Rehearsal {
    public let engine: Engine
    public let recorder: Recorder
    public let chords: [(time: Double, chord: Chord)]   // when the engine took each chord
    public let start: Double, end: Double
}

/// Plays `chords` into a fresh engine the way a left hand would: each chord a little rolled
/// (`roll` seconds between notes), `late` seconds after its bar line (negative is early).
public func rehearse(_ config: Config, chords: [Chord], barsPerChord: Int = 1, loops: Int = 1,
                     scene: String? = nil, late: Double = 0, roll: Double = 0.004,
                     bank: VoicingBank? = nil) throws -> Rehearsal {
    var config = config
    config.inputs = [InputSpec(port: "rehearsal", channel: nil, zone: nil)]
    config.autoStart = true
    let recorder = Recorder()
    let engine = try Engine(config: config, sink: recorder)
    engine.bank = bank
    var taken: [(time: Double, chord: Chord)] = []
    engine.onChord = { taken.append(($0, $1)) }
    if let scene { try engine.applyScene(scene, at: 0) }
    let sequence = Array(Array(repeating: chords, count: loops).joined())
    var held: [Int] = []
    for (j, c) in sequence.enumerated() {
        let t = j == 0 ? 0 : engine.stepTime(j * barsPerChord * engine.stepsPerBar) + late
        engine.run(until: t)
        for n in held { engine.noteOff(n, channel: 0, input: 0, at: t) }
        held = leftHand(c)
        for (i, n) in held.enumerated() {
            engine.run(until: t + Double(i) * roll)
            engine.noteOn(n, channel: 0, input: 0, at: t + Double(i) * roll)
        }
        if j == 0 { engine.run(until: Double(held.count) * roll + 0.1) }   // the first chord starts the band
    }
    let start = engine.stepTime(0), end = engine.stepTime(sequence.count * barsPerChord * engine.stepsPerBar)
    engine.run(until: end)
    engine.stop(at: end)
    return Rehearsal(engine: engine, recorder: recorder, chords: taken, start: start, end: end)
}

extension Rehearsal {
    func chord(at t: Double) -> Chord? { chords.last { $0.time <= t + 1e-9 }?.chord }

    var noteOns: [Recorder.Message] { recorder.messages.filter { $0.part >= 0 && $0.bytes[0] & 0xF0 == 0x90 } }

    /// Bar by bar: the chord, then each part's notes at their beat.sixteenth.
    public var text: String {
        let e = engine, step = e.stepDuration, bar = Double(e.stepsPerBar) * step
        let bars = Int(((end - start) / bar).rounded())
        var lines: [String] = []
        for b in 0..<bars {
            let t0 = start + Double(b) * bar
            let changes = chords.filter { $0.time >= t0 - 1e-9 && $0.time < t0 + bar - 1e-9 }.map { $0.chord.description }
            lines.append("bar \(b + 1)  " + (changes.isEmpty ? "(\(chord(at: t0)?.description ?? "-"))" : changes.joined(separator: " → ")))
            for (i, p) in e.parts.enumerated() {
                let ons = noteOns.filter { $0.part == i && $0.time >= t0 - step * 0.25 && $0.time < t0 + bar - step * 0.25 }
                guard !ons.isEmpty else { continue }
                var items: [String] = [], j = 0
                while j < ons.count {
                    var group = [ons[j]]
                    while j + group.count < ons.count && ons[j + group.count].time - ons[j].time < 0.002 { group.append(ons[j + group.count]) }
                    let s = Int(((ons[j].time - t0) / step + 0.25).rounded(.down))
                    let names = group.map { noteName(Int($0.bytes[1])) }
                    items.append("\(s / 4 + 1).\(s % 4 + 1) " + (names.count == 1 ? names[0] : "[" + names.joined(separator: " ") + "]"))
                    j += group.count
                }
                lines.append("  " + p.name.padding(toLength: 6, withPad: " ", startingAt: 0) + items.joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What would go wrong on a synth: notes started twice or never ended, ends with no start,
    /// a mono part sounding two notes, notes outside a part's range, keyboard notes outside the
    /// chord's palette.
    public var problems: [String] {
        var problems: [String] = [], on: [Int: Double] = [:], sounding: [Int: Int] = [:]
        let e = engine
        for m in recorder.messages where m.part >= 0 {
            let status = m.bytes[0] & 0xF0, note = Int(m.bytes[1])
            guard status == 0x90 || status == 0x80 else { continue }
            let p = e.parts[m.part], key = m.output * 2048 + Int(m.bytes[0] & 0x0F) * 128 + note
            let what = "\(p.name) \(noteName(note)) at \(String(format: "%.3f", m.time - start)) s"
            if status == 0x90 {
                if on[key] != nil { problems.append("\(what) started while already sounding") }
                on[key] = m.time
                sounding[m.part, default: 0] += 1
                if !p.range.contains(note) { problems.append("\(what) is outside \(noteName(p.range.lowerBound))-\(noteName(p.range.upperBound))") }
                if p.mono && !p.legato && sounding[m.part]! > 1 { problems.append("\(what) overlaps another note of a mono part") }
                if p.kind != .bass, let c = chord(at: m.time), !c.palette(1).contains(mod12(note)) { problems.append("\(what) is not in \(c)") }
            } else {
                if on[key] == nil { problems.append("\(what) ended without starting") }
                on[key] = nil
                sounding[m.part, default: 0] -= 1
            }
        }
        for k in on.keys.sorted() { problems.append("\(noteName(k % 128)) on channel \(k / 128 % 16 + 1) never ended") }
        return problems
    }

    /// Every note with its start and length (seconds from the band's start), the chords and the
    /// parts, for drawing a piano roll.
    public var json: Data {
        let e = engine
        var open: [Int: (t: Double, v: Int, part: Int)] = [:], notes: [[String: Any]] = []
        func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        for m in recorder.messages where m.part >= 0 {
            let status = m.bytes[0] & 0xF0
            guard status == 0x90 || status == 0x80 else { continue }
            let key = m.output * 2048 + Int(m.bytes[0] & 0x0F) * 128 + Int(m.bytes[1])
            if status == 0x90 { open[key] = (m.time, Int(m.bytes[2]), m.part) }
            else if let o = open.removeValue(forKey: key) {
                notes.append(["p": o.part, "n": Int(m.bytes[1]), "t": r3(o.t - start), "d": r3(m.time - o.t), "v": o.v])
            }
        }
        let object: [String: Any] = [
            "tempo": e.tempo, "bar": r3(Double(e.stepsPerBar) * e.stepDuration), "length": r3(end - start),
            "parts": e.parts.map { ["name": $0.name, "kind": $0.kind.rawValue, "style": $0.style.name] },
            "chords": chords.map { ["t": r3(max(0, $0.time - start)), "name": $0.chord.description] },
            "notes": notes,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A type 1 MIDI file: a conductor track with the tempo and the chords as markers, then one
    /// track per part.
    public var midiFile: Data {
        let e = engine, ppq = 480
        func ticks(_ t: Double) -> Int { max(0, Int(((t - start) * e.tempo / 60 * Double(ppq)).rounded())) }
        func vlq(_ v: Int) -> [UInt8] {
            var v = v, out = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            return out
        }
        func be(_ v: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } }
        func meta(_ type: UInt8, _ s: String) -> [UInt8] { let b = Array(s.utf8); return [0xFF, type] + vlq(b.count) + b }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be(body.count, 4) + body }

        let us = Int(60_000_000 / e.tempo)
        var conductor: [UInt8] = [0] + meta(0x03, "continuo") + [0, 0xFF, 0x51, 0x03] + be(us, 3)
        var last = 0
        for (t, c) in chords {
            conductor += vlq(ticks(t) - last) + meta(0x06, c.description)
            last = ticks(t)
        }
        var tracks = [conductor + [0, 0xFF, 0x2F, 0]]
        for (i, p) in e.parts.enumerated() {
            var track: [UInt8] = [0] + meta(0x03, p.name)
            last = 0
            for m in recorder.messages where m.part == i {
                track += vlq(max(0, ticks(m.time) - last)) + m.bytes
                last = max(last, ticks(m.time))
            }
            tracks.append(track + [0, 0xFF, 0x2F, 0])
        }
        return Data(chunk("MThd", be(1, 2) + be(tracks.count, 2) + be(ppq, 2)) + tracks.flatMap { chunk("MTrk", $0) })
    }
}
