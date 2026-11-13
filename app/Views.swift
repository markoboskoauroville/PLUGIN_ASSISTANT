import SwiftUI

struct StepButton: View {
    let n: Int?
    let word: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let n = n {
                    Text("\(n)").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24)
                        .background(Circle().strokeBorder(enabled ? Color.accentColor : Color.gray, lineWidth: 1))
                        .scaleEffect(hover && enabled ? 1.15 : 1)
                }
                Text(word).font(.system(size: 14, weight: .semibold)).underline(hover && enabled)
            }
            .foregroundStyle(enabled ? Color.primary : Color.gray)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0; if $0 && enabled { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .accessibilityLabel(word)
    }
}

/// One thin horizontal line: RMS fill, a short peak-hold tick; green, amber above -12, red above -3.
struct VU: View {
    let peak: Float
    let rms: Float
    let hold: Float
    static func frac(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }
    static func color(_ db: Float) -> Color { db > -3 ? .red : (db > -12 ? .orange : .green) }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1)
                Rectangle().fill(VU.color(rms)).frame(width: g.size.width * VU.frac(rms), height: 3)
                Rectangle().fill(VU.color(hold)).frame(width: 2, height: 7).offset(x: max(0, g.size.width * VU.frac(hold) - 2))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 8)
        .accessibilityLabel("level")
    }
}

struct Cell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddSheet: View {
    @EnvironmentObject var s: Store
    @Binding var shown: Bool
    @State private var q = ""
    var list: [PluginInfo] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty ? s.plugins : s.plugins.filter { $0.name.lowercased().contains(t) || $0.manufacturer.lowercased().contains(t) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search plug-ins", text: $q).textFieldStyle(.roundedBorder)
                StepButton(n: nil, word: "CLOSE") { shown = false }
            }
            List(list, id: \.id) { p in
                Button {
                    Task { _ = await s.add(p.id); shown = false }
                } label: {
                    VStack(alignment: .leading) { Text(p.name); Text(p.manufacturer).font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 480)
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Store
    @State private var adding = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Plugin Assistant (Mantra)").font(.system(size: 15, weight: .semibold))
                Spacer()
                StepButton(n: nil, word: "ON", enabled: !s.on) { s.turnOn() }
                StepButton(n: nil, word: "OFF", enabled: s.on) { s.turnOff() }
                Text("v\(VERSION)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Cell(label: "STATE", value: s.on ? "ON" : "OFF")
                        Cell(label: "LATENCY", value: s.on ? String(format: "%.1f ms", s.latency) : "-")
                        Cell(label: "BUFFER", value: "\(s.frames) frames")
                        Cell(label: "API", value: s.port > 0 ? "127.0.0.1:\(s.port)" : "starting")
                    }
                    if !s.error.isEmpty { Text(s.error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("1").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).background(Circle().strokeBorder(Color.accentColor, lineWidth: 1)); Text("MICROPHONE").font(.system(size: 14, weight: .semibold)) }
                        HStack(spacing: 10) {
                        Picker("", selection: Binding(get: { s.inputUID }, set: { s.setInput($0) })) {
                            ForEach(s.inputs, id: \.uid) { Text($0.name).tag($0.uid) }
                        }.labelsHidden().frame(maxWidth: 260)
                            VU(peak: s.inPeak, rms: s.inRms, hold: s.inHold).frame(minWidth: 80)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("2").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).background(Circle().strokeBorder(Color.accentColor, lineWidth: 1)); Text("PLUG-INS").font(.system(size: 14, weight: .semibold)); Spacer(); StepButton(n: nil, word: "+ ADD PLUG-IN") { adding = true } }
                        if s.chain.isEmpty { Text("Empty rack: the microphone goes straight through.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(s.chain.enumerated()), id: \.element.id) { idx, c in
                            VStack(alignment: .leading, spacing: 4) {
                                Divider()
                                HStack(spacing: 10) {
                                    Text("\(idx + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.name).font(.system(size: 14, weight: .medium)).strikethrough(c.bypass).foregroundStyle(c.bypass ? .secondary : .primary)
                                        Text(c.manufacturer).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StepButton(n: nil, word: "UI") { s.rack.openUI(c.id) }
                                    StepButton(n: nil, word: c.bypass ? "BYPASSED" : "BYPASS") { s.bypass(c.id) }
                                    StepButton(n: nil, word: "UP", enabled: idx > 0) { s.move(c.id, to: idx - 1) }
                                    StepButton(n: nil, word: "DOWN", enabled: idx < s.chain.count - 1) { s.move(c.id, to: idx + 1) }
                                    StepButton(n: nil, word: "REMOVE") { s.remove(c.id) }
                                }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("3").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).background(Circle().strokeBorder(Color.accentColor, lineWidth: 1)); Text("OUTPUT (Chrome takes this as its microphone)").font(.system(size: 14, weight: .semibold)) }
                        HStack(spacing: 10) {
                        Picker("", selection: Binding(get: { s.outputUID }, set: { s.setOutput($0) })) {
                            ForEach(s.outputs, id: \.uid) { Text($0.name).tag($0.uid) }
                        }.labelsHidden().frame(maxWidth: 260)
                            VU(peak: s.outPeak, rms: s.outRms, hold: s.outHold).frame(minWidth: 80)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PRESETS").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("Name", text: $presetName).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                            StepButton(n: nil, word: "SAVE", enabled: !presetName.isEmpty) { _ = s.savePreset(presetName) }
                        }
                        ForEach(s.presets, id: \.self) { n in
                            HStack { Text(n); Spacer(); StepButton(n: nil, word: "LOAD") { Task { _ = await s.loadPreset(n) } } }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            Text("© 2026 Mantra Productions").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 16)
        }
        .sheet(isPresented: $adding) { AddSheet(shown: $adding).environmentObject(s) }
    }
}
