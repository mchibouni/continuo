// continuo: a band that follows the chords you play. See `continuo help`.

import CoreMIDI
import Foundation
import ContinuoCore

setvbuf(stdout, nil, _IOLBF, 0)

let help = """
continuo [--gm]             run the band (play a chord to start it); --gm also plays it on the
                            built-in General MIDI synth, to hear it with no synths attached
continuo render <chords>    rehearse a progression silently: bar-by-bar notes, checks, --out file.mid
                            options: --scene <name> --bars <per chord> --loops <n> --tempo <bpm>
                            --late <ms> (the player's timing, negative = early) --roll <ms between a chord's notes, 4>
                            --audio <file.m4a> (render on the built-in General MIDI synth) --json <file>
continuo ctl <command>      talk to the running band:
    start | stop | panic | status
    tempo <bpm> | swing <50-75> | feel <8|16>
    scene [<name or number>]
    chord <symbol>          as if you played it (Dm9, B♭13, Cmaj7/E, F♯m7♭5, A7alt)
    set <part>.<setting> <value>     e.g. set bass.density 0.5, set keys.style charleston,
                                     set arp.range 60 84 (any part setting from the config)
    mute | unmute | toggle <part…|all>
continuo chord <notes…>     name the chord in some notes (D2 F2 A2 C3 E3, or MIDI numbers)
continuo mine [--tag <style>] <folders or MIDI files>…   [--tag <style> <more>…]
                            learn players' voicings into the bank (~/.config/continuo/bank.json);
                            --out <file>, --min <times a voicing must turn up to stay, 2>
continuo voicings <chords>  the bank's voicings for some chords, most used first (--tag <style>, --top <n>)
continuo styles             the rhythms each kind of part can play
continuo ports              MIDI sources and destinations
continuo init               write the standard config to ~/.config/continuo/config.json to edit
Options: --config <file> (default ~/.config/continuo/config.json, else the built-in one)
         --bank <file|none> (default ~/.config/continuo/bank.json when it exists)
"""

var args = Array(CommandLine.arguments.dropFirst())
var signalSources: [DispatchSourceSignal] = []

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func need<T>(_ value: T?, _ message: @autoclosure () -> String) -> T {
    guard let value else { fail(message()) }
    return value
}

let home = FileManager.default.homeDirectoryForCurrentUser
let defaultConfig = home.appendingPathComponent(".config/continuo/config.json")
let configPath = option("--config")
let defaultBank = home.appendingPathComponent(".config/continuo/bank.json")
let bankPath = option("--bank")

func loadConfig(quiet: Bool = false) -> Config {
    let url = configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultConfig
    if configPath == nil && !FileManager.default.fileExists(atPath: url.path) {
        if !quiet { print("using the built-in config (continuo init writes it to \(url.path) to edit)") }
        return Config.standard
    }
    do { return try Config.load(url) } catch { fail("\(url.path): \(error)") }
}

/// The voicing bank: --bank, else the default one if `continuo mine` has written it.
func loadBank(quiet: Bool = false) -> VoicingBank? {
    if bankPath == "none" { return nil }
    let url = bankPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultBank
    guard bankPath != nil || FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
        let bank = try VoicingBank.load(url)
        if !quiet { print("voicings from \(url.path): \(bank.shapes.count) shapes (\(bank.tags.joined(separator: ", ")))") }
        return bank
    } catch { fail("\(url.path): \(error)") }
}

// options alone (continuo --gm) mean run
let command = args.first.map { $0.hasPrefix("--") ? "run" : $0 } ?? "run"
if args.first == command { args.removeFirst() }

switch command {
case "run":
    let config = loadConfig()
    let live: Live
    do { live = try Live(config: config) } catch { fail("\(error)") }
    live.engine.bank = loadBank()
    if args.contains("--gm") {
        do { live.gm = try GeneralMIDI() } catch { fail("the built-in synth didn't start: \(error)") }
        live.gm!.choosePrograms(live.engine.parts)
        print("also playing on the built-in General MIDI synth, through the default audio output")
    }
    do { try serveControl { live.control($0) } } catch { fail("\(error)") }
    do { try live.start() } catch { fail("\(error)") }
    print(live.engine.status())
    print("play a chord to start; continuo ctl … to steer it; ctrl-c ends every note and quits")
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: s, queue: .main)
        source.setEventHandler { live.shutdown(); exit(0) }
        source.resume()
        signalSources.append(source)
    }
    CFRunLoopRun()

case "render":
    var config = loadConfig(quiet: true)
    let scene = option("--scene"), out = option("--out"), audio = option("--audio"), json = option("--json")
    let bars = Int(option("--bars") ?? "1") ?? 1, loops = Int(option("--loops") ?? "1") ?? 1
    let late = (Double(option("--late") ?? "0") ?? 0) / 1000
    let roll = (Double(option("--roll") ?? "4") ?? 4) / 1000
    if let t = option("--tempo").flatMap(Double.init) { config.tempo = t }
    let symbols = args.flatMap { $0.split(separator: " ").map(String.init) }
    guard !symbols.isEmpty else { fail("continuo render Dm9 G13 Cmaj9 …") }
    let chords = symbols.map { s in need(parseChord(s), "can't read the chord \(s)") }
    do {
        let r = try rehearse(config, chords: chords, barsPerChord: bars, loops: loops, scene: scene, late: late, roll: roll,
                             bank: loadBank())
        print(r.text)
        print("\n\(r.engine.corrections) hits re-voiced after they started (a chord change that came late)")
        let problems = r.problems
        print(problems.isEmpty ? "\nchecks: clean (every note ends, mono parts stay mono, ranges and harmony hold)"
                               : "\n\(problems.count) problems:\n" + problems.prefix(20).joined(separator: "\n"))
        if let out {
            try r.midiFile.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
            print("wrote \(out)")
        }
        if let json {
            try r.json.write(to: URL(fileURLWithPath: (json as NSString).expandingTildeInPath))
            print("wrote \(json)")
        }
        if let audio {
            try GeneralMIDI.render(r, to: URL(fileURLWithPath: (audio as NSString).expandingTildeInPath))
            print("wrote \(audio) (the built-in General MIDI synth)")
        }
        exit(problems.isEmpty ? 0 : 2)
    } catch { fail("\(error)") }

case "ctl":
    guard let reply = sendControl(args.joined(separator: " ")) else { fail("no answer: is continuo running?") }
    print(reply)

case "chord":
    let notes = args.flatMap { $0.split(separator: " ").map(String.init) }.map { s in need(parseNote(s), "can't read the note \(s)") }
    guard let c = detectChord(notes) else { fail("continuo chord D2 F2 A2 C3 E3") }
    print(c)

case "mine":
    var tag = "misc", out = defaultBank, minimum = 2, sources: [(path: String, tag: String)] = []
    var i = 0
    while i < args.count {
        let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
        switch a {
        case "--tag": tag = need(next, "--tag needs a style name"); i += 2
        case "--out": out = URL(fileURLWithPath: (need(next, "--out needs a file") as NSString).expandingTildeInPath); i += 2
        case "--min": minimum = need(next.flatMap { Int($0) }, "--min needs a number"); i += 2
        default: sources.append((a, tag)); i += 1
        }
    }
    guard !sources.isEmpty else { fail("continuo mine --tag jazz ~/MIDI/jazz --tag soul ~/MIDI/soul") }
    var miner = VoicingMiner(), read = 0, unreadable = 0
    for (path, tag) in sources {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { fail("\(path) doesn't exist") }
        let files = isDir.boolValue
            ? (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                .filter { ["mid", "midi"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("._") }
                .sorted { $0.path < $1.path }
            : [url]
        for f in files {
            do { miner.add(try MIDIFile(contentsOf: f), tag: tag); read += 1 } catch { unreadable += 1 }
            if read % 500 == 0 && read > 0 { print("  \(read) files…") }
        }
    }
    let bank = miner.bank(minimum: minimum)
    do {
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bank.write(to: out)
    } catch { fail("\(out.path): \(error)") }
    print("read \(read) files" + (unreadable > 0 ? ", \(unreadable) unreadable" : "") + ": \(miner.strikes) chord strikes, \(miner.kept) kept")
    for t in bank.tags {
        let mine = bank.shapes.filter { $0.tag == t }
        print("  \(t.padding(toLength: 8, withPad: " ", startingAt: 0)) \(bank.files[t] ?? 0) files, \(mine.count) voicings")
    }
    print("wrote \(out.path) (\(bank.shapes.count) voicings used at least \(minimum) times)")

case "voicings":
    let tags = option("--tag").map { Set($0.split(separator: ",").map(String.init)) }
    let top = Int(option("--top") ?? "10") ?? 10
    let bank = need(loadBank(quiet: true), "no bank yet: continuo mine … writes one to \(defaultBank.path)")
    guard !args.isEmpty else { fail("continuo voicings Dm9 G13 Cmaj9") }
    for symbol in args {
        let c = need(parseChord(symbol), "can't read the chord \(symbol)")
        let found = bank.shapes(for: c, tags: tags)
        print("\(c)  (\(found.count) voicings)")
        for v in found.prefix(top) {
            print("  " + v.notes.map(noteName).joined(separator: " ").padding(toLength: 30, withPad: " ", startingAt: 0) + " \(v.n)×  \(v.tag)")
        }
    }

case "styles":
    for kind in Kind.allCases {
        print(kind.rawValue)
        for s in styles where s.kind == kind { print("  \(s.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(s.about)") }
    }

case "ports":
    print("sources (inputs):")
    for e in sources() { print("  \(displayName(e))") }
    print("destinations (outputs):")
    for e in destinations() { print("  \(displayName(e))") }

case "init":
    if FileManager.default.fileExists(atPath: defaultConfig.path) && !args.contains("--force") {
        fail("\(defaultConfig.path) exists (continuo init --force replaces it)")
    }
    try? FileManager.default.createDirectory(at: defaultConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try Data(standardJSON.utf8).write(to: defaultConfig) } catch { fail("\(error)") }
    print("wrote \(defaultConfig.path)")

case "help", "-h", "--help":
    print(help)

default:
    fail(help)
}
