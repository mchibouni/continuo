// Apple's built-in General MIDI synth, for hearing continuo with no synths attached: live
// beside the MIDI outputs (`continuo --gm`), or rendering a rehearsal to an audio file.

import AVFoundation
import AudioToolbox
import ContinuoCore

final class GeneralMIDI {
    // GM programs (1-128) for parts that don't name one: finger bass, electric piano, saw lead
    static let defaults: [Kind: Int] = [.bass: 34, .comp: 5, .arp: 82, .drums: 1]   // drums play channel 10's kit whatever the program

    let engine = AVAudioEngine()
    let synth = AVAudioUnitMIDIInstrument(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

    init(renderingAt sampleRate: Double? = nil) throws {
        engine.attach(synth)
        engine.connect(synth, to: engine.mainMixerNode, format: nil)
        if let sampleRate {
            try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!,
                                                 maximumFrameCount: 512)
        }
        try engine.start()
    }

    /// A channel message, `offset` frames into the next render.
    func send(_ bytes: [UInt8], offset: UInt32 = 0) {
        guard let s = bytes.first, s < 0xF0 else { return }
        MusicDeviceMIDIEvent(synth.audioUnit, UInt32(s), UInt32(bytes.count > 1 ? bytes[1] : 0), UInt32(bytes.count > 2 ? bytes[2] : 0), offset)
    }

    func choosePrograms(_ parts: [Part]) {
        for p in parts { send([0xC0 | UInt8(p.channel), UInt8((p.program ?? GeneralMIDI.defaults[p.kind]!) - 1)]) }
    }

    /// Plays a rehearsal's messages into the synth, each on its exact sample, and writes AAC.
    static func render(_ r: Rehearsal, to url: URL, sampleRate: Double = 48000, tail: Double = 2.5) throws {
        let gm = try GeneralMIDI(renderingAt: sampleRate)
        gm.choosePrograms(r.engine.parts)
        let buffer = AVAudioPCMBuffer(pcmFormat: gm.engine.manualRenderingFormat, frameCapacity: gm.engine.manualRenderingMaximumFrameCount)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let messages = r.recorder.messages
        let total = AVAudioFramePosition((r.end - r.start + tail) * sampleRate)
        var position: AVAudioFramePosition = 0, next = 0
        while position < total {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total - position))
            while next < messages.count {
                let f = AVAudioFramePosition(((messages[next].time - r.start) * sampleRate).rounded())
                if f >= position + AVAudioFramePosition(frames) { break }
                gm.send(messages[next].bytes, offset: UInt32(max(0, f - position)))
                next += 1
            }
            guard try gm.engine.renderOffline(frames, to: buffer) == .success else { throw ConfigError("the synth stopped rendering") }
            try file.write(from: buffer)
            position += AVAudioFramePosition(frames)
        }
    }
}
