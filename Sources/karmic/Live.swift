// The engine on real MIDI: chords in from the configured sources, the parts out through
// karmic's own port or other destinations, on a real-time thread that sends every message
// stamped with the host time it belongs to (CoreMIDI holds early ones until then).

import CoreMIDI
import Foundation
import KarmicCore

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func seconds(_ host: UInt64) -> Double { Double(host) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }
func hostTime(_ s: Double) -> UInt64 { UInt64(max(0, s) * 1e9 * Double(timebase.denom) / Double(timebase.numer)) }
func now() -> Double { seconds(mach_absolute_time()) }

func displayName(_ e: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() else { return "?" }
    return n as String
}

func endpoints(_ count: Int, _ get: (Int) -> MIDIEndpointRef) -> [MIDIEndpointRef] { (0..<count).map(get) }
func sources() -> [MIDIEndpointRef] { endpoints(MIDIGetNumberOfSources()) { MIDIGetSource($0) } }
func destinations() -> [MIDIEndpointRef] { endpoints(MIDIGetNumberOfDestinations()) { MIDIGetDestination($0) } }

final class Live: Sink {
    let lock = NSLock()
    let wake = DispatchSemaphore(value: 0)
    var engine: Engine!
    let config: Config
    let outputs: [OutputSpec]
    var client = MIDIClientRef(), outPort = MIDIPortRef(), inPort = MIDIPortRef(), source = MIDIEndpointRef()
    var targets: [MIDIEndpointRef]
    var connected = Set<MIDIEndpointRef>()
    let list = UnsafeMutablePointer<MIDIEventList>.allocate(capacity: 1)
    let logQueue = DispatchQueue(label: "karmic.log")

    init(config: Config) throws {
        self.config = config
        outputs = config.outputs ?? [OutputSpec(name: "karmic", port: "virtual")]
        targets = Array(repeating: 0, count: outputs.count)
        engine = try Engine(config: config, sink: self)
        engine.onLog = { [weak self] line in self?.log(line) }
    }

    func log(_ line: String) {
        let stamp = Date()
        logQueue.async {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            print("\(f.string(from: stamp))  \(line)")
        }
    }

    func send(_ bytes: [UInt8], output: Int, at time: Double, part: Int) {
        guard let status = bytes.first else { return }
        var word: UInt32 = status >= 0xF0
            ? 0x1000_0000 | UInt32(status) << 16
            : 0x2000_0000 | UInt32(status) << 16 | UInt32(bytes.count > 1 ? bytes[1] : 0) << 8 | UInt32(bytes.count > 2 ? bytes[2] : 0)
        let packet = MIDIEventListInit(list, ._1_0)
        _ = MIDIEventListAdd(list, MemoryLayout<MIDIEventList>.size, packet, hostTime(time), 1, &word)
        if outputs[output].port == "virtual" {
            MIDIReceivedEventList(source, list)
        } else if targets[output] != 0 {
            MIDISendEventList(outPort, targets[output], list)
        }
    }

    func start() throws {
        var status = MIDIClientCreateWithBlock("karmic" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { self?.connect() }
        }
        guard status == noErr else { throw ConfigError("can't open CoreMIDI (\(status))") }
        if outputs.contains(where: { $0.port == "virtual" }) {
            MIDISourceCreateWithProtocol(client, "karmic" as CFString, ._1_0, &source)
            MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x4B52_4D43)   // fixed, so synths find it again
        }
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        status = MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, ref in
            self?.receive(list, input: Int(bitPattern: ref) - 1)
        }
        guard status == noErr else { throw ConfigError("can't open a MIDI input (\(status))") }
        connect()
        let thread = Thread { [unowned self] in self.loop() }
        thread.name = "karmic"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Finds the configured sources and destinations; again whenever devices come and go.
    func connect() {
        lock.lock(); defer { lock.unlock() }
        let srcs = sources()
        for (i, spec) in (config.inputs ?? []).enumerated() {
            let matches = srcs.filter { displayName($0) == spec.port && $0 != source }
            if matches.isEmpty { log("input \(spec.port): not there yet") }
            for s in matches where !connected.contains(s) {
                MIDIPortConnectSource(inPort, s, UnsafeMutableRawPointer(bitPattern: i + 1))
                connected.insert(s)
                log("input \(spec.port), channel \(spec.channel.map(String.init) ?? "any")" + (spec.zone.map { ", notes \(noteName($0[0]))-\(noteName($0[1]))" } ?? ""))
            }
        }
        connected = connected.intersection(srcs)
        let dsts = destinations()
        for (i, o) in outputs.enumerated() where o.port != "virtual" {
            let found = dsts.first { displayName($0) == o.port } ?? 0
            if found != targets[i] { log("output \(o.name) → \(o.port)" + (found == 0 ? ": not there" : "")) }
            targets[i] = found
        }
    }

    func receive(_ list: UnsafePointer<MIDIEventList>, input: Int) {
        var events: [(time: Double, status: UInt8, note: Int)] = []
        let sizes = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        var packet = UnsafeRawPointer(list) + MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!
        for _ in 0..<list.pointee.numPackets {
            let p = packet.assumingMemoryBound(to: MIDIEventPacket.self)
            let count = Int(p.pointee.wordCount)
            let words = packet + MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
            let t = p.pointee.timeStamp == 0 ? now() : seconds(p.pointee.timeStamp)
            var i = 0
            while i < count {
                let w = words.load(fromByteOffset: i * 4, as: UInt32.self)
                if w >> 28 == 2 {   // a MIDI 1.0 channel message
                    var status = UInt8(w >> 16 & 0xFF)
                    if status & 0xF0 == 0x90 && w & 0x7F == 0 { status = 0x80 | status & 0x0F }
                    if status & 0xF0 == 0x90 || status & 0xF0 == 0x80 { events.append((t, status, Int(w >> 8 & 0x7F))) }
                }
                i += sizes[Int(w >> 28)]
            }
            packet = words + count * 4
        }
        guard !events.isEmpty else { return }
        lock.lock()
        for e in events {
            let channel = Int(e.status & 0x0F)
            if e.status & 0xF0 == 0x90 { engine.noteOn(e.note, channel: channel, input: input, at: e.time) }
            else { engine.noteOff(e.note, channel: channel, input: input, at: e.time) }
        }
        lock.unlock()
        wake.signal()
    }

    /// Runs a control line from the socket.
    func control(_ line: String) -> String {
        lock.lock()
        let reply = engine.control(line, at: now())
        lock.unlock()
        wake.signal()
        return reply
    }

    func loop() {
        realtime()
        while true {
            lock.lock()
            let due = engine.nextWake()
            lock.unlock()
            if due == .infinity {
                wake.wait()
            } else if due - 0.001 > now() {
                _ = wake.wait(timeout: DispatchTime(uptimeNanoseconds: UInt64((due - 0.001) * 1e9)))
            }
            lock.lock()
            engine.run(until: now() + 0.001)
            lock.unlock()
        }
    }

    /// Asks for the scheduling a MIDI sequencer needs: woken on time, not when convenient.
    func realtime() {
        let ms = Double(timebase.denom) / Double(timebase.numer) * 1e6
        var policy = thread_time_constraint_policy_data_t(period: 0, computation: UInt32(0.5 * ms), constraint: UInt32(1 * ms), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if r != KERN_SUCCESS { log("no real-time scheduling (\(r)), timing may wobble") }
    }

    func shutdown() {
        lock.lock()
        _ = engine.control("panic", at: now())
        lock.unlock()
        usleep(20_000)   // let CoreMIDI deliver the note-offs
    }
}

let controlPort: UInt16 = 47130

func loopback() -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = controlPort.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    return a
}

/// Text commands over UDP on 127.0.0.1, one per datagram; the reply goes back to the sender.
func serveControl(_ handle: @escaping (String) -> String) throws {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    var addr = loopback()
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { throw ConfigError("port \(controlPort) is taken: is karmic already running?") }
    Thread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard n > 0 else { continue }
            let line = String(decoding: buffer[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = Array(handle(line).utf8)
            _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, length) } }
        }
    }.start()
}

/// Sends one command to a running karmic and returns its reply.
func sendControl(_ line: String) -> String? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = loopback()
    let bytes = Array(line.utf8)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var buffer = [UInt8](repeating: 0, count: 65536)
    let n = recv(fd, &buffer, buffer.count, 0)
    return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : nil
}
