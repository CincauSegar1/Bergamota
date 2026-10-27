import SwiftUI
import AppKit

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var logs = model.logs
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    TextField("Search", text: $logs.searchText).textFieldStyle(.roundedBorder)
                    Toggle(isOn: $logs.follow) { Label("Follow", systemImage: "arrow.down.to.line") }.toggleStyle(.button)
                    Toggle(isOn: $logs.paused) { Label("Pause", systemImage: "pause") }.toggleStyle(.button)
                    Button { logs.clear() } label: { Label("Clear", systemImage: "trash") }
                }
                HStack(spacing: 6) {
                    ForEach(LogTag.allCases) { tag in
                        let on = logs.activeTags.contains(tag)
                        Button {
                            if on { logs.activeTags.remove(tag) } else { logs.activeTags.insert(tag) }
                        } label: {
                            Text(tag.rawValue).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 3)
                                .background(on ? tagColor(tag) : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                    if !logs.activeTags.isEmpty { Button("All") { logs.activeTags = [] }.buttonStyle(.link) }
                    Spacer()
                    Toggle(isOn: Binding(get: { logs.recording }, set: { $0 ? logs.startRecording() : logs.userStopRecording() })) {
                        Label("Record to logs/", systemImage: "record.circle")
                    }.toggleStyle(.button).tint(.red)
                    Button { logs.saveBuffer() } label: { Label("Save buffer", systemImage: "square.and.arrow.down") }
                    Button { copyVisible() } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logs.visible) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(lineColor(line.tags))
                                .fixedSize()
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: logs.visible.last?.id) { _, id in
                    if logs.follow, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Circle().fill(logs.listening ? .green : .red).frame(width: 8, height: 8)
                Text(logs.listening ? "Listening on udp/5140" : (logs.listenError ?? "Not listening"))
                if !logs.listening { Button("Retry") { logs.restart() }.controlSize(.small) }
                Spacer()
                if let s = logs.statusMessage { Text(s).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                Text("\(logs.linesPerSecond) lines/s  |  showing \(logs.visible.count) of \(logs.bufferedCount)  |  total \(logs.totalReceived)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption).padding(8)
        }
        .navigationTitle("Live Log")
    }

    private func copyVisible() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logs.visible.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

func tagColor(_ t: LogTag) -> Color {
    switch t { case .usb: .blue; case .gpu: .purple; case .wlan: .teal; case .fb: .indigo; case .crash: .red }
}

func lineColor(_ tags: UInt8) -> Color {
    if tags & LogTag.crash.bit != 0 { return .red }
    for t in LogTag.allCases where tags & t.bit != 0 { return tagColor(t) }
    return .primary
}
