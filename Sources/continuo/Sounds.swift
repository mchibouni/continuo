// Rendering a rehearsal through instrument plugins (Arturia's V Collection, Omnisphere…)
// instead of the built-in General MIDI synth. A sounds file names the plugin for each part,
// and per scene:
//
//   { "parts": { "bass": "Mini V4", "keys": "Stage-73 V2", "pad": "Jup-8 V4" },
//     "scenes": { "funk": { "keys": "Clavinet V" }, "jazz": { "bass": "gm" } },
//     "gain": { "Mini V4": -4 }, "reverb": 14 }
//
// "gm" is the built-in synth with the part's program. Plugins play the patch they open with
// and never get program changes. Plugins only show up for processes in the user's login
// session: run this from a normal terminal (`continuo sounds` lists what it can see).

import AVFoundation
import AudioToolbox
import ContinuoCore

struct SoundsFile: Codable {
    var parts: [String: String]?
    var scenes: [String: [String: String]]?
    var gain: [String: Double]?   // dB, by plugin or part name
    var reverb: Double?           // wet %, 0 for none

    static func load(_ url: URL) throws -> SoundsFile { try JSONDecoder().decode(SoundsFile.self, from: Data(contentsOf: url)) }

    func sound(for part: String, scene: String?) -> String {
        scene.flatMap { scenes?[$0]?[part] } ?? parts?[part] ?? "gm"
    }
}

enum Sounds {
    /// The instrument plugins this process can see, as "Maker: Name".
    static func available() -> [AVAudioUnitComponent] {
        let any = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: 0,
                                            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: any)
    }

    static func find(_ name: String) -> AVAudioUnitComponent? {
        let all = available()
        return all.first { "\($0.manufacturerName): \($0.name)" == name } ?? all.first { $0.name == name }
            ?? all.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    /// Plays a rehearsal's messages into each part's instrument, each on its exact sample, and
    /// writes AAC. On the main thread, as the plugins do their own setup there: rendering from
    /// another thread at the same time crashes some of them.
    @MainActor
    static func render(_ r: Rehearsal, scene: String?, sounds: SoundsFile, to url: URL,
                       sampleRate: Double = 48000, tail: Double = 3) async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)

        // every part's destination: its own plugin, or the shared General MIDI synth
        var plugin: [Int: AUScheduleMIDIEventBlock] = [:]
        var gm: AVAudioUnitMIDIInstrument? = nil
        for (i, p) in r.engine.parts.enumerated() {
            let name = sounds.sound(for: p.name, scene: scene)
            let db = sounds.gain?[name] ?? sounds.gain?[p.name] ?? 0
            if name == "gm" {
                if gm == nil {
                    let synth = AVAudioUnitMIDIInstrument(audioComponentDescription: AudioComponentDescription(
                        componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
                        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
                    engine.attach(synth)
                    engine.connect(synth, to: engine.mainMixerNode, format: nil)
                    gm = synth
                }
                continue
            }
            guard let component = find(name) else {
                throw ConfigError("no instrument plugin called \(name) here (continuo sounds lists them; plugins only show up in your login session)")
            }
            let unit = try await AVAudioUnit.instantiate(with: component.audioComponentDescription, options: [])
            engine.attach(unit)
            engine.connect(unit, to: engine.mainMixerNode, format: format)
            (unit as? AVAudioMixing)?.volume = Float(pow(10, db / 20))
            guard let schedule = unit.auAudioUnit.scheduleMIDIEventBlock else { throw ConfigError("\(name) takes no MIDI") }
            plugin[i] = schedule
        }
        if let wet = sounds.reverb, wet > 0 {
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = Float(min(100, wet))
            engine.attach(reverb)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: reverb, format: format)
            engine.connect(reverb, to: engine.outputNode, format: format)
        }
        try engine.start()
        try await Task.sleep(nanoseconds: 500_000_000)   // let the plugins finish loading

        if let gm {
            for p in r.engine.parts where plugin[r.engine.parts.firstIndex { $0 === p }!] == nil {
                let program = UInt8((p.program ?? GeneralMIDI.defaults[p.kind]!) - 1)
                MusicDeviceMIDIEvent(gm.audioUnit, UInt32(0xC0 | p.channel), UInt32(program), 0, 0)
            }
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let messages = r.recorder.messages.filter { $0.part >= 0 }
        let total = AVAudioFramePosition((r.end - r.start + tail) * sampleRate)
        var position: AVAudioFramePosition = 0, next = 0
        while position < total {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total - position))
            while next < messages.count {
                let m = messages[next]
                let f = AVAudioFramePosition(((m.time - r.start) * sampleRate).rounded())
                if f >= position + AVAudioFramePosition(frames) { break }
                let offset = max(0, f - position)
                if let send = plugin[m.part] {
                    if m.bytes[0] & 0xF0 != 0xC0 {   // a General MIDI program number would change the plugin's patch
                        m.bytes.withUnsafeBufferPointer { send(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, m.bytes.count, $0.baseAddress!) }
                    }
                } else if let gm, let s = m.bytes.first, s < 0xF0 {
                    MusicDeviceMIDIEvent(gm.audioUnit, UInt32(s), UInt32(m.bytes.count > 1 ? m.bytes[1] : 0),
                                         UInt32(m.bytes.count > 2 ? m.bytes[2] : 0), UInt32(offset))
                }
                next += 1
            }
            guard try engine.renderOffline(frames, to: buffer) == .success else { throw ConfigError("the instruments stopped rendering") }
            try file.write(from: buffer)
            position += AVAudioFramePosition(frames)
        }
        engine.stop()
    }
}
