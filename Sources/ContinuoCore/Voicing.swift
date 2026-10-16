// Where each note of a chord goes on a keyboard part.

/// Voices a chord for a comping part: the colors that matter most (3rd and 7th, then tensions
/// as complexity rises, the fifth only if there's room), inside the range, as close as possible
/// to the previous voicing so the voices move by small steps, and never muddy low down.
/// Rootless leaves the root to the bass part once the chord has enough other notes.
public func voice(_ chord: Chord, voices: Int, lo: Int, hi: Int, complexity: Double,
                  rootless: Bool, previous: [Int]) -> [Int] {
    let tensions = complexity >= 0.4 ? Array(chord.q.tensions.prefix(complexity >= 0.7 ? 2 : 1)) : []
    var tones = chord.q.tones
    if rootless && tones.count - 1 + tensions.count >= 3 { tones.removeAll { $0 == 0 } }
    var wanted = Array(tones.prefix(2)) + tensions + tones.dropFirst(2)
    while wanted.count > voices, let i = wanted.firstIndex(of: 7) { wanted.remove(at: i) }
    wanted = Array(wanted.prefix(voices))
    let fillers = (tones.contains(0) ? [0] : []) + [tones.contains(7) ? 7 : tones[0]]
    var f = 0
    while wanted.count < voices && f < 4 { wanted.append(fillers[f % fillers.count]); f += 1 }
    let pcs = wanted.map { mod12(chord.root + $0) }

    let center = Double(lo + hi) / 2
    let options = pcs.map { pc in Array(stride(from: lo + mod12(pc - lo), through: hi, by: 12)) }
    let flatNine = chord.q.tones.contains(1)
    var best: [Int] = [], bestCost = Double.infinity, pick: [Int] = []

    func consider(strict: Bool) {
        let s = pick.sorted()
        if strict {
            for (a, b) in zip(s, s.dropFirst()) {
                let d = b - a
                if (d < 3 && a < 55) || (d < 5 && a < 48) || (d < 7 && a < 41) { return }
            }
            if s.last! - s.first! > (voices >= 5 ? 26 : 21) { return }
        }
        let mean = Double(s.reduce(0, +)) / Double(s.count)
        var cost = 0.0
        if previous.isEmpty {
            cost = abs(mean - center)
        } else {
            for n in s { cost += Double(previous.map { abs($0 - n) }.min()!) }
            for p in previous { cost += Double(s.map { abs($0 - p) }.min()!) }
            cost += 0.5 * Double(abs(s.last! - previous.max()!)) + 0.25 * abs(mean - center)
        }
        for i in 0..<s.count {
            for j in (i + 1)..<s.count where s[j] - s[i] == 13 && !flatNine { cost += 6 }
        }
        for (a, b) in zip(s, s.dropFirst()) {
            if b - a > 9 { cost += Double(b - a - 9) * 0.6 }   // a hole in the middle of the chord
            if b - a == 1 { cost += 1.5 }                      // a cluster
        }
        if s.count >= 2 && s[s.count - 1] - s[s.count - 2] == 1 { cost += 3 }   // and worse on top
        if cost < bestCost - 1e-9 { bestCost = cost; best = s }
    }
    func walk(_ i: Int, strict: Bool) {
        if i == options.count { consider(strict: strict); return }
        for n in options[i] where !pick.contains(n) {
            pick.append(n); walk(i + 1, strict: strict); pick.removeLast()
        }
    }
    walk(0, strict: true)
    if best.isEmpty { walk(0, strict: false) }
    if best.isEmpty {   // a range too narrow for the doubled notes: one of each, near the middle
        best = Set(pcs).map { pc in lo + mod12(pc - lo) + (Double(lo + mod12(pc - lo)) + 6 < center ? 12 : 0) }
            .filter { $0 <= hi }.sorted()
    }
    return best
}
