// Reading standard MIDI files: every note with its start and length in seconds, following the
// file's tempo changes, and the first program each channel asks for.

import Foundation

public struct MIDINote {
    public let start: Double, length: Double   // seconds
    public let note: Int, velocity: Int, channel: Int
}

public struct MIDIFile {
    public private(set) var notes: [MIDINote] = []
    public private(set) var programs: [Int: Int] = [:]   // channel → program, 0-127
    public private(set) var tempo = 120.0                 // the first tempo, bpm

    public init(contentsOf url: URL) throws { try self.init(Data(contentsOf: url)) }

    public init(_ data: Data) throws {
        let d = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }
        func u16(_ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
        guard d.count >= 14, d[0..<4] == [0x4D, 0x54, 0x68, 0x64] else { throw ConfigError("not a MIDI file") }
        let tracks = u16(10), division = u16(12)
        guard division & 0x8000 == 0, division > 0 else { throw ConfigError("SMPTE-timed MIDI files aren't supported") }
        var pos = 8 + u32(4)
        var tempos: [(tick: Int, usPerQuarter: Int)] = []
        var raw: [(on: Int, off: Int, note: Int, velocity: Int, channel: Int)] = []

        for _ in 0..<tracks {
            guard pos + 8 <= d.count, d[pos..<pos + 4] == [0x4D, 0x54, 0x72, 0x6B] else { break }
            var p = pos + 8, tick = 0, status: UInt8 = 0
            let end = min(d.count, p + u32(pos + 4))
            var open: [Int: [(tick: Int, velocity: Int)]] = [:]   // channel * 128 + note
            func vlq() -> Int {
                var v = 0
                while p < end {
                    let b = d[p]; p += 1
                    v = v << 7 | Int(b & 0x7F)
                    if b & 0x80 == 0 { break }
                }
                return v
            }
            while p < end {
                tick += vlq()
                guard p < end else { break }
                if d[p] & 0x80 != 0 { status = d[p]; p += 1 }
                if status == 0xFF {
                    guard p < end else { break }
                    let type = d[p]; p += 1
                    let length = vlq()
                    if type == 0x51 && length == 3 && p + 3 <= end {
                        tempos.append((tick, Int(d[p]) << 16 | Int(d[p + 1]) << 8 | Int(d[p + 2])))
                    }
                    p += length
                } else if status == 0xF0 || status == 0xF7 {
                    p += vlq()
                } else {
                    let kind = status & 0xF0, channel = Int(status & 0x0F)
                    guard p < end else { break }
                    let a = Int(d[p]); p += 1
                    var b = 0
                    if kind != 0xC0 && kind != 0xD0 { guard p < end else { break }; b = Int(d[p]); p += 1 }
                    let key = channel * 128 + a
                    if kind == 0x90 && b > 0 {
                        open[key, default: []].append((tick, b))
                    } else if kind == 0x80 || kind == 0x90 {
                        if var starts = open[key], !starts.isEmpty {
                            let s = starts.removeFirst()
                            open[key] = starts
                            raw.append((s.tick, tick, a, s.velocity, channel))
                        }
                    } else if kind == 0xC0 && programs[channel] == nil {
                        programs[channel] = a
                    }
                }
            }
            pos += 8 + u32(pos + 4)
        }

        // ticks to seconds through the tempo map
        tempos.sort { $0.tick < $1.tick }
        if tempos.first?.tick != 0 { tempos.insert((0, tempos.first?.usPerQuarter ?? 500_000), at: 0) }
        tempo = 60_000_000 / Double(tempos[0].usPerQuarter)
        var marks: [(tick: Int, seconds: Double, perTick: Double)] = []
        var seconds = 0.0
        for (i, t) in tempos.enumerated() {
            if i > 0 { seconds += Double(t.tick - tempos[i - 1].tick) * marks[i - 1].perTick }
            marks.append((t.tick, seconds, Double(t.usPerQuarter) / 1e6 / Double(division)))
        }
        func time(_ tick: Int) -> Double {
            var lo = 0, hi = marks.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if marks[mid].tick <= tick { lo = mid } else { hi = mid - 1 } }
            return marks[lo].seconds + Double(tick - marks[lo].tick) * marks[lo].perTick
        }
        notes = raw.map { r in
            let s = time(r.on)
            return MIDINote(start: s, length: max(0, time(r.off) - s), note: r.note, velocity: r.velocity, channel: r.channel)
        }.sorted { ($0.start, $0.note) < ($1.start, $1.note) }
    }
}
