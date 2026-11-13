import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreAudioKit
import AppKit

struct AudioDev: Hashable { let id: AudioDeviceID; let uid: String; let name: String; let ins: Int; let outs: Int }

struct PluginInfo { let id: String; let name: String; let manufacturer: String; let desc: AudioComponentDescription }

enum RackErr: Error, LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

enum Dev {
    static let sys = AudioObjectID(kAudioObjectSystemObject)

    static func all() -> [AudioDev] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = str(id, kAudioObjectPropertyName), let uid = str(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDev(id: id, uid: uid, name: name, ins: channels(id, kAudioObjectPropertyScopeInput), outs: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    static func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard st == noErr, let c = cf else { return nil }
        return c.takeRetainedValue() as String
    }

    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }

    static func setBuffer(_ id: AudioObjectID, _ frames: UInt32) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = frames
        _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func buffer(_ id: AudioObjectID) -> UInt32 { u32(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal) }

    /// device latency + safety offset + buffer, in frames, for one direction
    static func frames(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Double {
        Double(u32(id, kAudioDevicePropertyLatency, scope) + u32(id, kAudioDevicePropertySafetyOffset, scope) + buffer(id))
    }

    static func defaultInput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &d)
        return d
    }
}

final class Meter: @unchecked Sendable {
    var inPeak: Float = -90
    var inRms: Float = -90
    var outPeak: Float = -90
    var outRms: Float = -90
    static func levels(_ b: AVAudioPCMBuffer) -> (Float, Float) {
        guard let ch = b.floatChannelData else { return (-90, -90) }
        var m: Float = 0
        var sum: Float = 0
        let n = Int(b.frameLength)
        let c = Int(b.format.channelCount)
        if n == 0 || c == 0 { return (-90, -90) }
        for k in 0..<c {
            let p = ch[k]
            for i in 0..<n { let v = abs(p[i]); if v > m { m = v }; sum += v * v }
        }
        let rms = (sum / Float(n * c)).squareRoot()
        return (20 * log10(max(m, 1e-4)), 20 * log10(max(rms, 1e-4)))
    }
}

final class Slot {
    let id = UUID().uuidString.lowercased()
    let info: PluginInfo
    var bypass = false
    var unit: AVAudioUnit
    init(info: PluginInfo, unit: AVAudioUnit) { self.info = info; self.unit = unit }
}

@MainActor
final class Rack {
    let engine = AVAudioEngine()
    let head = AVAudioMixerNode()
    let tail = AVAudioMixerNode()
    let meter = Meter()
    var slots: [Slot] = []
    var windows: [String: NSWindow] = [:]
    private(set) var running = false
    private(set) var catalogCache: [PluginInfo] = []

    init() {
        engine.attach(head)
        engine.attach(tail)
    }

    static func hex(_ v: UInt32) -> String { String(format: "%08x", v) }

    func catalog(refresh: Bool = false) -> [PluginInfo] {
        if !catalogCache.isEmpty && !refresh { return catalogCache }
        var seen = Set<String>()
        var out: [PluginInfo] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let d = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: d) {
                let ad = c.audioComponentDescription
                let id = "\(Rack.hex(ad.componentType))-\(Rack.hex(ad.componentSubType))-\(Rack.hex(ad.componentManufacturer))"
                if seen.contains(id) { continue }
                seen.insert(id)
                out.append(PluginInfo(id: id, name: c.name, manufacturer: c.manufacturerName, desc: ad))
            }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        catalogCache = out
        return out
    }

    func find(_ q: String) -> PluginInfo? {
        let cat = catalog()
        if let e = cat.first(where: { $0.id == q }) { return e }
        let l = q.lowercased()
        return cat.first(where: { $0.name.lowercased() == l }) ?? cat.first(where: { $0.name.lowercased().contains(l) })
    }

    func instantiate(_ d: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: d, options: []) { u, e in
                if let u = u { c.resume(returning: u) } else { c.resume(throwing: e ?? RackErr.msg("could not load the plug-in")) }
            }
        }
    }

    func add(_ info: PluginInfo, at: Int? = nil) async throws -> Slot {
        let u = try await instantiate(info.desc)
        let sr = running ? engine.inputNode.outputFormat(forBus: 0).sampleRate : 48000
        if let f = AVAudioFormat(standardFormatWithSampleRate: sr > 0 ? sr : 48000, channels: 2) {
            do {
                try u.auAudioUnit.inputBusses[0].setFormat(f)
                try u.auAudioUnit.outputBusses[0].setFormat(f)
            } catch { throw RackErr.msg("\(info.name) does not accept a stereo 32-bit chain") }
        }
        let s = Slot(info: info, unit: u)
        engine.attach(u)
        if let at = at, at >= 0, at < slots.count { slots.insert(s, at: at) } else { slots.append(s) }
        rebuild()
        return s
    }

    func remove(_ id: String) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let s = slots.remove(at: i)
        windows[id]?.close(); windows[id] = nil
        let was = engine.isRunning
        if was { engine.stop() }
        engine.disconnectNodeOutput(s.unit)
        engine.disconnectNodeInput(s.unit)
        engine.detach(s.unit)
        if was { wire(); try? engine.start(); taps() }
    }

    func move(_ id: String, to: Int) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let s = slots.remove(at: i)
        slots.insert(s, at: max(0, min(slots.count, to)))
        rebuild()
    }

    func setBypass(_ id: String, _ v: Bool) {
        guard let s = slots.first(where: { $0.id == id }) else { return }
        s.bypass = v
        s.unit.auAudioUnit.shouldBypassEffect = v
    }

    func clear() { for s in slots.map({ $0.id }) { remove(s) } }

    /// stop, rewire, restart: only when the order or the set of plug-ins changes
    func rebuild() {
        guard engine.isRunning else { return }
        engine.stop()
        wire()
        try? engine.start()
        taps()
    }

    private func wire() {
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeOutput(head)
        for s in slots { engine.disconnectNodeOutput(s.unit) }
        engine.disconnectNodeOutput(tail)
        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        let sr = inFmt.sampleRate > 0 ? inFmt.sampleRate : 48000
        guard let st = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        if inFmt.channelCount > 0 { engine.connect(engine.inputNode, to: head, format: inFmt) }
        var prev: AVAudioNode = head
        for s in slots {
            if s.unit.engine == nil { engine.attach(s.unit) }
            engine.connect(prev, to: s.unit, format: st)
            prev = s.unit
        }
        engine.connect(prev, to: tail, format: st)
        engine.connect(tail, to: engine.mainMixerNode, format: st)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }

    private func setDevice(_ n: AVAudioIONode, _ id: AudioDeviceID) throws {
        guard let au = n.audioUnit else { throw RackErr.msg("no audio unit on the device node") }
        var d = id
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { throw RackErr.msg("could not select the device (\(st))") }
    }

    func start(input: AudioDev, output: AudioDev, frames: UInt32) throws {
        stopMonitor()
        stop()
        Dev.setBuffer(input.id, frames)
        Dev.setBuffer(output.id, frames)
        try setDevice(engine.inputNode, input.id)
        try setDevice(engine.outputNode, output.id)
        if engine.inputNode.outputFormat(forBus: 0).channelCount == 0 { throw RackErr.msg("the microphone gives no audio (permission?)") }
        wire()
        engine.prepare()
        try engine.start()
        taps()
        running = true
    }

    // light input-only tap while the rack is OFF, so the input meter shows the microphone before ON
    private var monitor: AVAudioEngine?

    func startMonitor(input: AudioDev, output: AudioDev) {
        stopMonitor()
        let e = AVAudioEngine()
        do {
            var d = input.id
            guard let au = e.inputNode.audioUnit else { return }
            guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return }
            // the engine's output side is parked on the chosen output (BlackHole) so it never touches the speakers
            var o = output.id
            if let ou = e.outputNode.audioUnit { _ = AudioUnitSetProperty(ou, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &o, UInt32(MemoryLayout<AudioDeviceID>.size)) }
            let f = e.inputNode.outputFormat(forBus: 0)
            if f.channelCount == 0 { return }
            let m = meter
            e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: f) { b, _ in let l = Meter.levels(b); m.inPeak = l.0; m.inRms = l.1 }
            e.prepare()
            try e.start()
            monitor = e
        } catch { monitor = nil }
    }

    func stopMonitor() {
        if let e = monitor { e.inputNode.removeTap(onBus: 0); e.stop() }
        monitor = nil
    }

    func stop() {
        head.removeTap(onBus: 0)
        tail.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        running = false
        meter.outPeak = -90; meter.outRms = -90; if monitor == nil { meter.inPeak = -90; meter.inRms = -90 }
    }

    private func taps() {
        head.removeTap(onBus: 0)
        tail.removeTap(onBus: 0)
        let m = meter
        head.installTap(onBus: 0, bufferSize: 512, format: head.outputFormat(forBus: 0)) { b, _ in let l = Meter.levels(b); m.inPeak = l.0; m.inRms = l.1 }
        tail.installTap(onBus: 0, bufferSize: 512, format: tail.outputFormat(forBus: 0)) { b, _ in let l = Meter.levels(b); m.outPeak = l.0; m.outRms = l.1 }
    }

    func latencyMs(input: AudioDev?, output: AudioDev?) -> Double {
        guard running, let i = input, let o = output else { return 0 }
        let sr = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard sr > 0 else { return 0 }
        var ms = (Dev.frames(i.id, kAudioObjectPropertyScopeInput) + Dev.frames(o.id, kAudioObjectPropertyScopeOutput)) / sr * 1000
        for s in slots where !s.bypass { ms += s.unit.auAudioUnit.latency * 1000 }
        return ms
    }

    func openUI(_ id: String) {
        guard let s = slots.first(where: { $0.id == id }) else { return }
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let title = s.info.name
        let unit = s.unit
        unit.auAudioUnit.requestViewController { vc in
            Task { @MainActor in
                let controller: NSViewController
                if let vc = vc { controller = vc } else {
                    controller = NSViewController()
                    controller.view = AUGenericView(audioUnit: unit.audioUnit)
                }
                let w = NSWindow(contentViewController: controller)
                w.title = title
                w.isReleasedWhenClosed = false
                w.center()
                self.windows[id] = w
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // presets
    func snapshot() -> [[String: Any]] {
        slots.map { s in
            var d: [String: Any] = ["plugin": s.info.id, "name": s.info.name, "bypass": s.bypass]
            if let fs = s.unit.auAudioUnit.fullState,
               let data = try? PropertyListSerialization.data(fromPropertyList: fs, format: .binary, options: 0) {
                d["state"] = data.base64EncodedString()
            }
            return d
        }
    }

    func restore(_ items: [[String: Any]]) async -> [String] {
        clear()
        var errs: [String] = []
        for it in items {
            guard let pid = it["plugin"] as? String, let info = find(pid) else { errs.append("missing plug-in \(it["name"] as? String ?? "?")"); continue }
            do {
                let s = try await add(info)
                if let b64 = it["state"] as? String, let data = Data(base64Encoded: b64),
                   let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    s.unit.auAudioUnit.fullState = obj
                }
                if let b = it["bypass"] as? Bool { setBypass(s.id, b) }
            } catch { errs.append(error.localizedDescription) }
        }
        return errs
    }
}
