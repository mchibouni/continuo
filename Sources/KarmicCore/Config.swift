// The config file: where the chords come from, where the parts go, the parts themselves and
// the scenes that switch them. Everything but a part's name and kind is optional.

import Foundation

public struct PartSpec: Codable {
    public var name: String?
    public var kind: Kind?
    public var style: String?
    public var out: String?          // an output's name
    public var channel: Int?         // 1-16
    public var range: [Int]?         // lowest and highest note
    public var density: Double?      // 0 only the strongest steps … 1 every step
    public var complexity: Double?   // 0 plain … 1 tensions and passing notes
    public var accent: Double?       // how much softer the weak steps are, 0-1
    public var gate: Double?         // note length as a share of its steps; the style's if unset
    public var swing: Double?        // 50 straight … 66 triplet … 75 dotted; the global one if unset
    public var feel: Int?            // swing sixteenths (16) or eighths (8)
    public var velocity: [Int]?      // softest and loudest
    public var voices: Int?          // comp: notes per chord
    public var span: Int?            // arp: octaves
    public var octave: Int?          // shifts the range
    public var loop: Int?            // bars before a riff or its variations repeat
    public var vary: Double?         // 0 the same every loop … 1 the weak steps come and go
    public var humanize: Double?     // timing spread in ms
    public var seed: Int?
    public var mute: Bool?
    public var mono: Bool?           // one note at a time
    public var legato: Bool?         // mono notes overlap a little, for glide
    public var retrigger: Bool?      // a held note changes when the chord does
    public var rootless: Bool?       // comp: leave the root to the bass
    public var program: Int?         // 1-128: a program change sent when the band starts
}

public struct InputSpec: Codable {
    public var port: String
    public var channel: Int?   // 1-16, or any
    public var zone: [Int]?    // the notes that count as the chord
    public init(port: String, channel: Int? = nil, zone: [Int]? = nil) { (self.port, self.channel, self.zone) = (port, channel, zone) }
}

public struct OutputSpec: Codable {
    public var name: String
    public var port: String    // "virtual" for karmic's own port, else a destination's name
    public init(name: String, port: String) { (self.name, self.port) = (name, port) }
}

public struct Scene: Codable {
    public var name: String
    public var tempo: Double?
    public var swing: Double?
    public var feel: Int?
    public var parts: [String: PartSpec]?
}

public struct Config: Codable {
    public var tempo: Double?
    public var swing: Double?
    public var feel: Int?
    public var stepsPerBar: Int?
    public var inputs: [InputSpec]?
    public var latch: Bool?        // keep playing the last chord after the keys come up
    public var autoStart: Bool?    // the first chord starts the band
    public var settle: Double?     // ms to wait for the rest of a chord's notes
    public var outputs: [OutputSpec]?
    public var clockOut: [String]?
    public var parts: [PartSpec]
    public var scenes: [Scene]?
    public var startScene: String?

    public static func load(_ url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public static var standard: Config { try! JSONDecoder().decode(Config.self, from: Data(standardJSON.utf8)) }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public let standardJSON = """
{
  "tempo": 98,
  "swing": 54,
  "inputs": [
    { "port": "USB MIDI Device", "channel": 1, "zone": [0, 64] },
    { "port": "Launchpad Music", "channel": 1 }
  ],
  "latch": true,
  "autoStart": true,
  "outputs": [ { "name": "karmic", "port": "virtual" } ],
  "clockOut": [],
  "parts": [
    { "name": "bass", "kind": "bass", "style": "funk",   "out": "karmic", "channel": 2 },
    { "name": "keys", "kind": "comp", "style": "stabs",  "out": "karmic", "channel": 3 },
    { "name": "arp",  "kind": "arp",  "style": "broken", "out": "karmic", "channel": 4 },
    { "name": "pad",  "kind": "comp", "style": "pad",    "out": "karmic", "channel": 5,
      "range": [48, 84], "voices": 5, "complexity": 0.8, "velocity": [45, 70], "mute": true }
  ],
  "scenes": [
    { "name": "funk", "swing": 56, "feel": 16, "parts": {
        "bass": { "style": "funk" }, "keys": { "style": "stabs", "mute": false },
        "arp": { "style": "broken", "mute": false }, "pad": { "mute": true } } },
    { "name": "house", "swing": 52, "feel": 16, "parts": {
        "bass": { "style": "octaves" }, "keys": { "style": "offbeat", "mute": false },
        "arp": { "style": "up16", "mute": false }, "pad": { "mute": false } } },
    { "name": "jazz", "swing": 64, "feel": 8, "parts": {
        "bass": { "style": "walk" }, "keys": { "style": "charleston", "mute": false },
        "arp": { "mute": true }, "pad": { "mute": true } } },
    { "name": "bossa", "swing": 50, "feel": 16, "parts": {
        "bass": { "style": "bossa" }, "keys": { "style": "bossa", "mute": false },
        "arp": { "style": "updown8", "density": 0.4, "mute": false }, "pad": { "mute": true } } },
    { "name": "ballad", "swing": 50, "feel": 16, "parts": {
        "bass": { "style": "rootfive", "density": 0.5 }, "keys": { "style": "ballad", "mute": false },
        "arp": { "style": "updown8", "density": 0.5, "mute": false }, "pad": { "mute": false } } },
    { "name": "drive", "swing": 50, "feel": 16, "parts": {
        "bass": { "style": "pedal" }, "keys": { "style": "gate", "mute": false },
        "arp": { "style": "random", "mute": false }, "pad": { "mute": true } } }
  ],
  "startScene": "funk"
}
"""
