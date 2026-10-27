import SwiftUI
import AppKit

private struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ControlPlaneView: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    @State private var tagFilter: Set<LogTag> = []
    @State private var confirmSend = false
    @State private var showFlash = false
    @State private var actionMessage: String?
    @AppStorage("cpScreen") private var savedScreen = ""
    @AppStorage("cpFullScreen") private var wantFullScreen = false

    private let bg = Color(red: 0.04, green: 0.05, blue: 0.07)
    /// Layout scale from the window size: 1.0 at 1280x880 pt; an iPad as a Sidecar display (1180x820 or
    /// 1366x1024) or a small window shrinks everything proportionally instead of clipping, big displays grow it.
    @State private var s: CGFloat = 1
    private static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(0.55, min(1.6, min(size.width / 1280, size.height / 880)))
    }

    var body: some View {
        let m = model.monitor, q = model.queue
        // Rows take their natural height with equal-height cards; the log takes whatever is left.
        VStack(spacing: 18 * s) {
            ActivityBannerView(big: true, scale: s)
            HStack(spacing: 18 * s) {
                tile("PHONE", m.state.title.uppercased(), sub: "since \(m.stateSince.formatted(date: .omitted, time: .standard))", color: stateColor(m.state))
                batteryTile
                lastBootTile
            }
            .fixedSize(horizontal: false, vertical: true)
            MetricsStrip(s: s)
            HStack(spacing: 18 * s) {
                queueCard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ciCard.frame(width: 440 * s).frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            logCard.frame(maxHeight: .infinity)
        }
        .padding(24 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) { controls.padding(.horizontal, 24 * s).padding(.vertical, 12 * s).frame(maxWidth: .infinity).background(bg) }
        .background(bg)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { s = Self.scale(for: g.size) }
                .onChange(of: g.size) { _, n in s = Self.scale(for: n) }
        })
        .preferredColorScheme(.dark)
        .background(WindowAccessor { w in
            guard window == nil else { return }
            window = w
            w.setFrameAutosaveName("BergamotaControlPlane")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { applySavedPlacement() }
        })
        .confirmationDialog("Send the next image now?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send fastboot boot now", role: .destructive) { Task { actionMessage = await q.sendNow() } }
        } message: {
            Text("If the last boot left ABL hung, sending again can hang it further. Press only after re-entering fastboot (hold Power + Volume Down).")
        }
        .sheet(isPresented: $showFlash) { FlashPickerSheet() }
        .task { if model.ci.runs.isEmpty { await model.ci.refresh() }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 120_000_000_000); await model.ci.refresh() } }
    }

    // MARK: tiles

    private func tile(_ title: String, _ value: String, sub: String = "", color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 40 * s, weight: .heavy, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            if !sub.isEmpty { Text(sub).font(.system(size: 16 * s)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(18 * s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16 * s))
    }

    private var batteryTile: some View {
        let i = model.monitor.state == .ios ? model.monitor.info : nil
        let p = i?.batteryPercent
        return tile("BATTERY", p.map { "\($0)%" } ?? "--", sub: i.map { ($0.isCharging == true ? "charging" : "on battery") + ($0.powerSource.map { " | \($0)" } ?? "") } ?? "iOS not up",
                    color: (p ?? 100) < 20 ? .red : (p == nil ? .gray : .green))
    }

    private var lastBootTile: some View {
        let s = model.lastSent, f = model.lastFailed
        let latest = [s, f].compactMap { $0 }.max { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
        guard let it = latest, let at = it.sentAt else { return tile("LAST BOOT", "none", color: .gray) }
        let ok = it.status == .sent
        return tile("LAST BOOT", ok ? "SENT" : "FAILED", sub: "\(it.name)  \(at.formatted(date: .omitted, time: .standard))", color: ok ? .green : .red)
    }

    // MARK: queue

    private var queueCard: some View {
        let q = model.queue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("QUEUE").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
                Text(q.armed ? "ARMED" : "STOPPED").font(.system(size: 14 * s, weight: .heavy)).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(q.armed ? Color.orange : Color.gray.opacity(0.5), in: Capsule()).foregroundStyle(q.armed ? .black : .white)
                Spacer()
                if let first = q.pending.first, model.monitor.state.isFastboot, q.sending == nil, !q.flashing {
                    Button("Send now: \(first.name)") { confirmSend = true }.tint(.orange).controlSize(.large)
                }
            }
            if q.items.isEmpty { Text("empty").font(.system(size: 22 * s)).foregroundStyle(.secondary) }
            ForEach(q.items.suffix(6)) { it in
                HStack(spacing: 10) {
                    Image(systemName: icon(it.status)).foregroundStyle(color(it.status))
                    Text(it.name).font(.system(size: 22 * s, weight: .semibold)).lineLimit(1)
                    if q.largeWarns(it) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(BootQueue.largeWarning) }
                    Spacer()
                    if let t = it.sentAt { Text(t.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }
                }
            }
            Text(q.statusText).font(.system(size: 14 * s)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(18 * s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16 * s))
    }

    private func icon(_ s: QueueItem.Status) -> String {
        switch s { case .pending: "clock"; case .sending: "paperplane.fill"; case .sent: "checkmark.circle.fill"; case .failed: "xmark.octagon.fill" }
    }
    private func color(_ s: QueueItem.Status) -> Color {
        switch s { case .pending: .secondary; case .sending: .orange; case .sent: .green; case .failed: .red }
    }

    // MARK: CI

    private var ciCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CI  xnu.yml").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
            ForEach(CIModel.branches, id: \.self) { b in
                let run = model.ci.runs.first { $0.headBranch == b }
                HStack(spacing: 10) {
                    Image(systemName: ciIcon(run)).foregroundStyle(ciColor(run)).font(.system(size: 24 * s))
                    Text(b).font(.system(size: 22 * s, weight: .semibold))
                    Spacer()
                    if let r = run {
                        Text(r.shortSha).font(.system(size: 16 * s, design: .monospaced)).foregroundStyle(.secondary)
                        Text(r.createdAt.formatted(.relative(presentation: .numeric))).font(.system(size: 16 * s)).foregroundStyle(.secondary)
                    } else { Text("--").foregroundStyle(.secondary) }
                }
            }
            if let e = model.ci.error { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }
        .padding(18 * s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16 * s))
    }
    private func ciIcon(_ r: CIRun?) -> String {
        guard let r else { return "questionmark.circle" }
        if !r.isDone { return "circle.dotted" }
        return r.conclusion == "success" ? "checkmark.circle.fill" : (r.conclusion == "cancelled" ? "slash.circle" : "xmark.circle.fill")
    }
    private func ciColor(_ r: CIRun?) -> Color {
        guard let r else { return .gray }
        if !r.isDone { return .orange }
        return r.conclusion == "success" ? .green : (r.conclusion == "cancelled" ? .gray : .red)
    }

    // MARK: log

    private var logCard: some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LIVE LOG").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
                ForEach(LogTag.allCases) { tag in
                    let on = tagFilter.contains(tag)
                    Button { if on { tagFilter.remove(tag) } else { tagFilter.insert(tag) } } label: {
                        Text(tag.rawValue).font(.system(size: 12 * s, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(on ? tagColor(tag) : Color.white.opacity(0.12), in: Capsule()).foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("\(model.logs.linesPerSecond) lines/s").font(.system(size: 14 * s)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
            let fit = max(1, Int(geo.size.height / (19 * s)))
            let lines = model.logs.totalReceived >= 0 ? model.logs.tail(fit, tags: tagFilter) : []
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines) { l in
                    Text(l.text.isEmpty ? " " : l.text).font(.system(size: 15 * s, design: .monospaced)).lineLimit(1)
                        .foregroundStyle(l.tags & LogTag.crash.bit != 0 ? .red : (l.tags != 0 ? lineColor(l.tags) : Color.white.opacity(0.85)))
                }
                if lines.isEmpty { Text(model.logs.listening ? "waiting for kernel log on udp/5140..." : "log listener stopped").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 4 * 19 * s)
        }
        .padding(18 * s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16 * s))
    }

    // MARK: controls

    private var controls: some View {
        let q = model.queue, m = model.monitor
        return HStack(spacing: 14) {
            if let reboot = model.hooks.rebootToFastboot, [.ios, .recovery, .android].contains(m.state) {
                Button { Task { actionMessage = await reboot() } } label: { Label("Reboot to ABL fastboot", systemImage: "arrow.triangle.2.circlepath") }
                    .tint(.blue)
            }
            if let reboot = model.hooks.rebootToBergamota, m.state == .ios {
                Button { Task { actionMessage = await reboot() } } label: { Label("Reboot to Bergamota fastboot", systemImage: "leaf.circle.fill") }
                    .tint(.lime).foregroundStyle(.black)
            }
            Button { confirmSend = true } label: { Label("Send now", systemImage: "paperplane.fill") }
                .tint(.orange).disabled(!m.state.isFastboot || q.pending.isEmpty || q.sending != nil || q.flashing)
            if m.state == .fastboot {
                Button { Task { actionMessage = await model.tools.enterBergamota().1 } } label: { Label("Enter Bergamota fastboot", systemImage: "leaf.circle.fill") }
                    .tint(.lime).foregroundStyle(.black).disabled(model.tools.enteringBergamota || q.sending != nil || q.flashing)
                Button { showFlash = true } label: { Label("Flash userdata", systemImage: "externaldrive.fill.badge.exclamationmark") }
                    .tint(.red).disabled(q.sending != nil || q.flashing)
            }
            Button { q.disarm() } label: { Label("Stop", systemImage: "stop.fill") }.tint(.red).disabled(!q.armed)
            if let a = actionMessage { Text(a).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Menu {
                ForEach(NSScreen.screens, id: \.localizedName) { s in
                    Button("Move to \(s.localizedName)") { place(on: s, full: wantFullScreen) }
                }
                Divider()
                Toggle("Full screen on that display", isOn: Binding(get: { wantFullScreen }, set: { wantFullScreen = $0; applySavedPlacement(force: true) }))
            } label: { Label("Display", systemImage: "display") }
            Button { window?.toggleFullScreen(nil); wantFullScreen = !(window?.styleMask.contains(.fullScreen) ?? false) } label: {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .controlSize(.large).buttonStyle(.borderedProminent)
    }

    // MARK: placement

    private func screen(named n: String) -> NSScreen? { NSScreen.screens.first { $0.localizedName == n } }

    private func place(on s: NSScreen, full: Bool) {
        guard let w = window else { return }
        savedScreen = s.localizedName
        wantFullScreen = full
        let isFull = w.styleMask.contains(.fullScreen)
        func go() {
            let f = s.visibleFrame.insetBy(dx: 40, dy: 40)
            w.setFrame(f, display: true, animate: false)
            if full && !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
        if isFull { w.toggleFullScreen(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { go() } } else { go() }
    }

    private func applySavedPlacement(force: Bool = false) {
        guard let w = window else { return }
        if let s = screen(named: savedScreen) {
            if force || w.screen != s { place(on: s, full: wantFullScreen) }
            else if wantFullScreen && !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        } else if wantFullScreen && !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
    }
}
