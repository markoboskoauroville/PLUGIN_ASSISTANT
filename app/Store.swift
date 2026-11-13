import Foundation
import SwiftUI
import AVFoundation
import CoreAudio

struct ChainItem: Identifiable, Equatable {
    let id: String
    let plugin: String
    let name: String
    let manufacturer: String
    var bypass: Bool
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    let rack = Rack()
    let http = Http()
    @Published var on = false
    @Published var error = ""
    @Published var chain: [ChainItem] = []
    @Published var inputs: [AudioDev] = []
    @Published var outputs: [AudioDev] = []
    @Published var inputUID = UserDefaults.standard.string(forKey: "inputUID") ?? ""
    @Published var outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
    @Published var inDb: Float = -90
    @Published var outDb: Float = -90
    @Published var latency: Double = 0
    @Published var port = 0
    @Published var presets: [String] = []
    @Published var plugins: [PluginInfo] = []
    let frames: UInt32 = 128
    private var timer: Timer?
    private var started = false

    var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Plugin Assistant (Mantra)/presets")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func startServer() {
        if started { return }
        started = true
        refreshDevices()
        plugins = rack.catalog()
        refreshPresets()
        http.handler = { [weak self] m, p, b in
            guard let self = self else { return (500, Data()) }
            return await self.route(m, p, b)
        }
        http.onReady = { port in
            Task { @MainActor in
                Store.shared.port = Int(port)
                let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mantra/ports")
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                try? "\(port)\n".write(to: d.appendingPathComponent("plugin-assistant"), atomically: true, encoding: .utf8)
            }
        }
        http.start(8873)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { _ in
            Task { @MainActor in Store.shared.tick() }
        }
        Task { await restoreLast() }
    }

    func tick() {
        inDb = rack.meter.inDb
        outDb = rack.meter.outDb
        if on { latency = rack.latencyMs(input: dev(inputUID), output: dev(outputUID)) }
    }

    func refreshDevices() {
        let all = Dev.all()
        inputs = all.filter { $0.ins > 0 && !$0.name.localizedCaseInsensitiveContains("BlackHole") }
        outputs = all.filter { $0.outs > 0 && !$0.name.localizedCaseInsensitiveContains("ADAM") }
        if dev(inputUID) == nil || !inputs.contains(where: { $0.uid == inputUID }) {
            let d = Dev.defaultInput()
            inputUID = inputs.first(where: { $0.id == d })?.uid ?? inputs.first?.uid ?? ""
        }
        if !outputs.contains(where: { $0.uid == outputUID }) {
            outputUID = outputs.first(where: { $0.name == "BlackHole 2ch" })?.uid ?? outputs.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") })?.uid ?? ""
        }
    }

    func dev(_ uid: String) -> AudioDev? { Dev.all().first(where: { $0.uid == uid }) }

    func setInput(_ uid: String) {
        inputUID = uid
        UserDefaults.standard.set(uid, forKey: "inputUID")
        if on { _ = turnOn() }
    }

    func setOutput(_ uid: String) {
        outputUID = uid
        UserDefaults.standard.set(uid, forKey: "outputUID")
        if on { _ = turnOn() }
    }

    @discardableResult
    func turnOn() -> String? {
        refreshDevices()
        guard let i = dev(inputUID) else { error = "no microphone chosen"; return error }
        guard let o = dev(outputUID) else { error = "BlackHole 2ch not found: install it or choose an output"; return error }
        if o.name.localizedCaseInsensitiveContains("ADAM") { error = "never the ADAM"; return error }
        let go = {
            do {
                try self.rack.start(input: i, output: o, frames: self.frames)
                self.on = true
                self.error = ""
            } catch {
                self.rack.stop()
                self.on = false
                self.error = error.localizedDescription
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: go()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in if ok { go() } else { self.error = "microphone permission denied" } }
            }
            return "asking for microphone permission"
        default: error = "microphone permission denied: System Settings > Privacy > Microphone"
        }
        return error.isEmpty ? nil : error
    }

    func turnOff() {
        rack.stop()
        on = false
        latency = 0
    }

    func syncChain() {
        chain = rack.slots.map { ChainItem(id: $0.id, plugin: $0.info.id, name: $0.info.name, manufacturer: $0.info.manufacturer, bypass: $0.bypass) }
        saveLast()
    }

    func add(_ q: String, at: Int? = nil) async -> String? {
        guard let info = rack.find(q) else { return "plug-in not found: \(q)" }
        do { _ = try await rack.add(info, at: at); syncChain(); return nil } catch { self.error = error.localizedDescription; return error.localizedDescription }
    }
    func remove(_ id: String) { rack.remove(id); syncChain() }
    func move(_ id: String, to: Int) { rack.move(id, to: to); syncChain() }
    func bypass(_ id: String, _ v: Bool? = nil) {
        guard let s = rack.slots.first(where: { $0.id == id }) else { return }
        rack.setBypass(id, v ?? !s.bypass)
        syncChain()
    }

    // presets
    func safe(_ n: String) -> String { String(n.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }.prefix(60)) }
    func refreshPresets() {
        let f = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        presets = f.filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }.map { String($0.dropLast(5)) }.sorted()
    }
    func savePreset(_ name: String) -> Bool {
        let n = safe(name)
        if n.isEmpty { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: ["chain": rack.snapshot()], options: [.prettyPrinted]) else { return false }
        let ok = (try? data.write(to: dir.appendingPathComponent("\(n).json"))) != nil
        refreshPresets()
        return ok
    }
    func loadPreset(_ name: String, file: String? = nil) async -> [String]? {
        let n = file ?? "\(safe(name)).json"
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(n)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = o["chain"] as? [[String: Any]] else { return nil }
        let errs = await rack.restore(items)
        syncChain()
        return errs
    }
    private var saving = true
    func saveLast() {
        if saving { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["chain": rack.snapshot()]) { try? data.write(to: dir.appendingPathComponent("_last.json")) }
    }
    func restoreLast() async {
        _ = await loadPreset("", file: "_last.json")
        saving = false
    }

    // API
    func status() -> [String: Any] {
        [
            "app": "Plugin Assistant (Mantra)", "version": VERSION, "port": port,
            "on": on, "error": error,
            "input": dev(inputUID)?.name ?? "", "output": dev(outputUID)?.name ?? "",
            "bufferFrames": Int(frames),
            "latencyMs": (latency * 10).rounded() / 10,
            "levels": ["in": Double(rack.meter.inDb), "out": Double(rack.meter.outDb)],
            "chain": chain.map { ["id": $0.id, "plugin": $0.plugin, "name": $0.name, "manufacturer": $0.manufacturer, "bypass": $0.bypass] as [String: Any] }
        ]
    }

    func J(_ o: Any, _ code: Int = 200) -> (Int, Data) {
        (code, (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    func route(_ m: String, _ p: String, _ body: Data) async -> (Int, Data) {
        let b = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        switch (m, p) {
        case ("GET", "/status"): return J(status())
        case ("GET", "/plugins"):
            return J(["plugins": rack.catalog().map { ["id": $0.id, "name": $0.name, "manufacturer": $0.manufacturer] }])
        case ("GET", "/devices"):
            return J(["inputs": inputs.map { ["uid": $0.uid, "name": $0.name] }, "outputs": outputs.map { ["uid": $0.uid, "name": $0.name] }, "input": inputUID, "output": outputUID])
        case ("GET", "/presets"): refreshPresets(); return J(["presets": presets])
        case ("POST", "/on"):
            if let e = turnOn(), !on { return J(["ok": false, "error": e], 409) }
            return J(status())
        case ("POST", "/off"): turnOff(); return J(status())
        case ("POST", "/device"):
            if let i = b["input"] as? String { setInput(i) }
            if let o = b["output"] as? String { setOutput(o) }
            return J(status())
        case ("POST", "/chain"):
            let action = b["action"] as? String ?? ""
            let slot = b["slot"] as? String ?? ""
            switch action {
            case "add":
                if let e = await add(b["plugin"] as? String ?? "", at: b["at"] as? Int) { return J(["ok": false, "error": e], 400) }
            case "remove": remove(slot)
            case "move": move(slot, to: b["to"] as? Int ?? 0)
            case "bypass": bypass(slot, b["value"] as? Bool)
            default: return J(["ok": false, "error": "action: add | remove | move | bypass"], 400)
            }
            return J(status())
        case ("POST", "/preset/save"):
            return J(["ok": savePreset(b["name"] as? String ?? "")])
        case ("POST", "/preset/load"):
            guard let errs = await loadPreset(b["name"] as? String ?? "") else { return J(["ok": false, "error": "preset not found"], 404) }
            var s = status(); s["errors"] = errs
            return J(s)
        case ("POST", "/ui/open"):
            rack.openUI(b["slot"] as? String ?? "")
            return J(["ok": true])
        default: return J(["error": "not found"], 404)
        }
    }
}
