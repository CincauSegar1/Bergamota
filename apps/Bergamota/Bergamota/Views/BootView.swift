import SwiftUI

private enum BootTab: String, CaseIterable, Identifiable {
    case queue = "Queue", images = "Images", build = "Build", flash = "Flash"
    var id: String { rawValue }
}

private let sizeFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

struct BootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: BootTab = .queue

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(BootTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360).padding(10)
            Divider()
            switch tab {
            case .queue: QueuePane()
            case .images: ImagesPane(tab: $tab)
            case .build: BuildPane(tab: $tab)
            case .flash: FlashPane()
            }
        }
        .navigationTitle("Boot Queue")
        .onAppear { model.build.rescan() }
    }
}

// MARK: queue

private struct QueuePane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSend = false

    var body: some View {
        @Bindable var settings = model.settings
        let q = model.queue
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: q.armed ? "scope" : "pause.circle").font(.title)
                    .foregroundStyle(q.armed ? stateColor(model.monitor.state) : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(q.armed ? "Armed" : "Stopped").font(.headline)
                        if settings.allowRemoteStart {
                            Label("remote control on", systemImage: "antenna.radiowaves.left.and.right").font(.caption2.bold())
                                .padding(.horizontal, 7).padding(.vertical, 2).background(.blue.opacity(0.18), in: Capsule()).foregroundStyle(.blue)
                        }
                    }
                    if let b = q.autoRebootBadge {
                        Label(b, systemImage: "arrow.triangle.2.circlepath").font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background((b.contains("manual") ? Color.orange : Color.green).opacity(0.18), in: Capsule())
                            .foregroundStyle(b.contains("manual") ? Color.orange : Color.green)
                    }
                    Text(q.statusText).foregroundStyle(.secondary)
                    if let a = q.autoStatusText, a != q.statusText { Text(a).font(.caption).foregroundStyle(.secondary) }
                    if let n = q.note { Text(n).font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                Text(model.monitor.state.title).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(stateColor(model.monitor.state).opacity(0.2), in: Capsule())
                if q.armed { Button("Stop") { q.disarm() } }
                else { Button("Start") { q.arm() }.buttonStyle(.borderedProminent).disabled(q.pending.isEmpty) }
            }
            .padding(14)
            Divider()
            HStack {
                Toggle("If in OrangeFox, `adb reboot bootloader` first", isOn: $settings.rebootFromRecovery)
                Spacer()
                Text("One `fastboot boot` per fastboot appearance, never retried.").font(.caption).foregroundStyle(.secondary)
                Button("Clear finished") { q.clearFinished() }.disabled(!q.items.contains { $0.status == .sent || $0.status == .failed })
            }
            .padding(10)
            Divider()
            List {
                ForEach(q.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            statusIcon(item.status)
                            Text(item.name).font(.body.bold())
                            if item.flashesUserdata { Image(systemName: "externaldrive.fill.badge.exclamationmark").foregroundStyle(.red).help("flashes userdata first") }
                            Spacer()
                            if let t = item.sentAt { Text(t.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }
                            if item.status == .pending, item.id == q.pending.first?.id, model.monitor.state.isFastboot, q.sending == nil, !q.flashing {
                                Button("Send now") { confirmSend = true }.controlSize(.small).tint(.orange)
                            }
                            if item.status == .pending {
                                Button { q.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                                Button { q.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            }
                            if item.status != .sending { Button { q.remove(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
                        }
                        if item.flashesUserdata, item.name != item.autoLabel {
                            Label(item.autoLabel, systemImage: "externaldrive.fill").font(.caption).foregroundStyle(.red)
                        }
                        if item.needsManualFastboot {
                            Label("needs manual fastboot (hold Power + Volume Down)", systemImage: "hand.tap.fill").font(.caption).foregroundStyle(.orange)
                        } else if item.autoRebootTried, item.status == .pending {
                            Label("auto-reboot to fastboot sent", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                        }
                        if q.largeWarns(item) {
                            Label("\(BootQueue.largeWarning) (\(sizeFmt.string(fromByteCount: item.size)))", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.yellow)
                        }
                        if !item.output.isEmpty {
                            Text(item.output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .confirmationDialog("Send the next image now?", isPresented: $confirmSend, titleVisibility: .visible) {
                Button("Send fastboot boot now", role: .destructive) { Task { _ = await q.sendNow() } }
            } message: {
                Text("If the last boot left ABL hung, sending again can hang it further. Press only after re-entering fastboot (hold Power + Volume Down).")
            }
            .overlay { if q.items.isEmpty { ContentUnavailableView("Queue is empty", systemImage: "tray", description: Text("Add images from the Images or Build tab.")) } }
        }
    }

    @ViewBuilder private func statusIcon(_ s: QueueItem.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .sending: ProgressView().controlSize(.small)
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

// MARK: images

private struct ImagesPane: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: BootTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.settings.bootDir)/out/*.img (\(model.build.images.count))").font(.headline)
                Spacer()
                Button { model.build.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }.padding(10)
            Divider()
            Table(model.build.images) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Size") { img in
                    HStack(spacing: 4) {
                        Text(sizeFmt.string(fromByteCount: img.size))
                        if model.queue.largeWarns(img.size) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(BootQueue.largeWarning) }
                    }
                }.width(110)
                TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }.width(150)
                TableColumn("") { img in
                    Button("Add to queue") { model.queue.add(img.path); tab = .queue }.controlSize(.small)
                }.width(110)
            }
        }
    }
}

// MARK: build

private struct BuildPane: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: BootTab
    @State private var presetName = ""
    @State private var confirmOverwrite = false

    var body: some View {
        @Bindable var b = model.build
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Inputs") {
                    Picker("Kernel", selection: $b.kernelPath) {
                        if b.kernelPath.isEmpty { Text("(none found)").tag("") }
                        ForEach(b.kernels) { Text("\(b.kernelLabel($0))  \($0.date.formatted(date: .abbreviated, time: .shortened))").tag($0.path) }
                    }
                    Picker("ADT", selection: $b.adtPath) {
                        if b.adtPath.isEmpty { Text("(none found)").tag("") }
                        ForEach(b.adts) { Text($0.name).tag($0.path) }
                    }
                    TextField("Image name", text: $b.imageName, prompt: Text("e.g. 0131"))
                    if !b.imageName.isEmpty && !BuildModel.validName(b.imageName) {
                        Text("Use letters, digits, . _ - only.").font(.caption).foregroundStyle(.red)
                    }
                    if b.targetExists && !b.imageName.isEmpty {
                        Text("\(model.settings.bootImageBase)-\(b.imageName).img already exists and will be replaced.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Cmdline") {
                    Picker("Preset", selection: Binding(get: { b.selectedPresetID }, set: { b.applyPreset($0) })) {
                        ForEach(b.presets) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextEditor(text: $b.cmdline).font(.system(size: 11, design: .monospaced)).frame(height: 130)
                    HStack {
                        TextField("Save as preset", text: $presetName).textFieldStyle(.roundedBorder)
                        Button("Save") { b.saveCurrentAsPreset(named: presetName); presetName = "" }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Delete selected") { b.deleteSelectedPreset() }.disabled(b.selectedPresetID == nil)
                    }
                    Text(Presets.fileURL.path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                Section {
                    HStack {
                        Button {
                            if b.targetExists { confirmOverwrite = true } else { b.build() }
                        } label: { Label("Build image", systemImage: "hammer.fill") }
                            .buttonStyle(.borderedProminent).disabled(!b.canBuild)
                        if b.building { ProgressView().controlSize(.small) }
                        if let img = b.lastBuiltImage, model.queue.largeWarns(BootQueue.fileSize(img)) {
                            Label(BootQueue.largeWarning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
                        }
                        if let r = b.lastResult { Text(r).foregroundStyle(b.lastBuiltImage != nil ? .green : .red) }
                        Spacer()
                        if let img = b.lastBuiltImage { Button("Add to queue") { model.queue.add(img); tab = .queue } }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Output").font(.headline).padding(10)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(b.output.isEmpty ? "Build output appears here." : b.output)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(b.output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: b.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .confirmationDialog("Replace \(model.settings.bootImageBase)-\(b.imageName).img?", isPresented: $confirmOverwrite) {
            Button("Replace and build", role: .destructive) { b.build() }
        }
    }
}
