import SwiftUI

/// A line over the last ~2 minutes (x = time, so a gap in the data is a gap in the line). `range` nil = auto from the data.
struct Sparkline: View {
    var points: [(Date, Double)]
    var color: Color
    var range: ClosedRange<Double>? = nil
    var window: TimeInterval = MetricsHistory.window
    var zeroLine = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Canvas { g, size in
                let now = ctx.date
                let pts = points.filter { now.timeIntervalSince($0.0) <= window }
                guard pts.count >= 2 else { return }
                let vals = pts.map(\.1)
                var lo = range?.lowerBound ?? (vals.min() ?? 0), hi = range?.upperBound ?? (vals.max() ?? 1)
                if range == nil {
                    let pad = max((hi - lo) * 0.15, hi == lo ? max(abs(hi) * 0.1, 1) : 0)
                    lo -= pad; hi += pad
                }
                if zeroLine { lo = min(lo, 0); hi = max(hi, 0) }
                func xy(_ p: (Date, Double)) -> CGPoint {
                    CGPoint(x: size.width * (1 - now.timeIntervalSince(p.0) / window),
                            y: size.height * (1 - (min(max(p.1, lo), hi) - lo) / max(hi - lo, 1e-9)))
                }
                if zeroLine, lo < 0, hi > 0 {
                    var z = Path()
                    let y = size.height * (1 - (0 - lo) / (hi - lo))
                    z.move(to: CGPoint(x: 0, y: y)); z.addLine(to: CGPoint(x: size.width, y: y))
                    g.stroke(z, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                }
                var line = Path()
                var prev: Date?
                for p in pts {
                    if let pd = prev, p.0.timeIntervalSince(pd) > 8 { line.move(to: xy(p)) }     // data gap (> 4 missed polls)
                    else if prev == nil { line.move(to: xy(p)) } else { line.addLine(to: xy(p)) }
                    prev = p.0
                }
                g.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// Frequency bar: the filled part is cur / max.
struct FreqBar: View {
    var fraction: Double?
    var color: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                if let f = fraction {
                    Capsule().fill(color.gradient).frame(width: max(height, g.size.width * min(max(f, 0), 1)))
                        .animation(.easeOut(duration: 0.4), value: f)
                }
            }
        }
        .frame(height: height)
    }
}

struct RendererBadge: View {
    var r: RendererMetrics
    var size: CGFloat = 13
    static func color(_ mode: String) -> Color { mode == "fd630" ? .lime : (mode == "softpipe" ? .orange : .gray) }
    var body: some View {
        Text(r.label)
            .font(.system(size: size, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, size * 0.6).padding(.vertical, size * 0.2)
            .background(Self.color(r.mode), in: Capsule())
            .foregroundStyle(r.mode == "cpu" ? Color.white : Color.black)
    }
}

func gpuStateColor(_ s: String) -> Color {
    switch s {
    case "on": .green
    case "slumber": .cyan
    case "off": .gray
    case "lost": .red
    default: .secondary
    }
}

// MARK: Dashboard

struct PerformanceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mon = model.monitor
        Card(title: "Performance", symbol: "gauge.with.dots.needle.67percent") {
            if mon.state != .ios {
                Text("Available when iOS is up.").foregroundStyle(.secondary)
            } else if let m = mon.metrics {
                content(m, mon.metricsHistory)
            } else if let e = mon.metricsError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Waiting for the first sweetmetrics sample...") }
            }
        }
    }

    @ViewBuilder
    private func content(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // CPU
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU").font(.subheadline.bold()).foregroundStyle(.secondary)
                ForEach(m.clusters, id: \.id) { c in
                    let peak = max(c.maxKhz ?? 0, h.peakKhz(c.id), c.nominalMaxKhz)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(c.name)").font(.callout.bold())
                            Text("CPU \(c.cpus.first ?? 0)-\(c.cpus.last ?? 0)").font(.caption2).foregroundStyle(.tertiary)
                        }.frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            FreqBar(fraction: c.curKhz.map { Double($0) / Double(peak) }, color: .blue)
                            Text(c.modeText).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(c.curKhz.map(formatKhz) ?? "unknown").font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
                        Text(c.loadPct.map { String(format: "%.0f%%", $0) } ?? "--").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        Sparkline(points: h.cpu(c.id), color: .blue, range: 0...Double(peak)).frame(width: 110, height: 26)
                    }
                }
                if !m.cpuLoad.isEmpty {
                    HStack(spacing: 3) {
                        Text("load").font(.caption2).foregroundStyle(.tertiary).frame(width: 62, alignment: .leading)
                        ForEach(Array(m.cpuLoad.enumerated()), id: \.offset) { _, l in
                            FreqBar(fraction: l / 100, color: .teal, height: 5)
                        }
                    }
                }
            }
            Divider()
            // GPU + renderer
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GPU  Adreno 630").font(.subheadline.bold()).foregroundStyle(.secondary)
                    Text(m.gpu.state.uppercased()).font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 1)
                        .background(gpuStateColor(m.gpu.state).opacity(0.25), in: Capsule()).foregroundStyle(gpuStateColor(m.gpu.state))
                    Spacer()
                    RendererBadge(r: m.renderer)
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        FreqBar(fraction: m.gpu.mhz.map { $0 / (m.gpu.maxMhz ?? 710) }, color: .purple)
                        Text(gpuLine(m.gpu)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(m.gpu.mhz.map { String(format: "%.0f MHz", $0) } ?? "unknown").font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
                    Text(m.gpu.busyPct.map { String(format: "%.0f%%", $0) } ?? "--").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    Sparkline(points: h.gpu, color: .purple, range: 0...(m.gpu.maxMhz ?? 710)).frame(width: 110, height: 26)
                }
                Row(k: "Renderer", v: rendererDetail(m.renderer))
            }
            Divider()
            // Battery
            VStack(alignment: .leading, spacing: 6) {
                Text("Battery").font(.subheadline.bold()).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(m.battery.percent.map { String(format: "%.0f%%", $0) } ?? "--").font(.title3.bold().monospacedDigit()).frame(width: 62, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(batteryLine(m.battery)).font(.callout)
                        if let t = m.batteryTempC { Text(String(format: "%.1f \u{00B0}C", t)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(m.battery.currentMa.map(formatMa) ?? "mA unknown").font(.callout.monospacedDigit())
                    Sparkline(points: h.battery, color: .green, zeroLine: true).frame(width: 110, height: 26)
                }
            }
            let waiting = metricsWaiting(m)
            if !waiting.isEmpty || !m.errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(waiting, id: \.self) { Label($0, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("sample \(m.fetched.formatted(date: .omitted, time: .standard)), last 2 min in the plots (sweetmetrics schema \(m.schema))")
                .font(.caption2).foregroundStyle(.tertiary)
            if let e = model.monitor.metricsError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func gpuLine(_ g: GPUMetrics) -> String {
        var p: [String] = []
        if let l = g.level { p.append("level \(l)" + (g.levels.map { "/\($0)" } ?? "")) }
        if let f = g.freqMode { p.append(f == "gov" ? "governor" : f) }
        if g.clients > 0 { p.append("\(g.clients) client\(g.clients == 1 ? "" : "s")") }
        if let r = g.recoveries, r > 0 { p.append("\(r) recover\(r == 1 ? "y" : "ies")") }
        if p.isEmpty { return g.hasDCVS ? "" : (g.state == "absent" ? "no GPU driver" : "level/MHz/busy not reported yet") }
        return p.joined(separator: " | ")
    }
}

func rendererDetail(_ r: RendererMetrics) -> String {
    var p: [String] = []
    p.append("requested " + (r.requested == "off" ? "none" : r.requested))
    if let i = r.injected { p.append(i ? "shim injected" : "not injected") }
    p.append(r.gpuClientOpen ? "backboardd has the GPU open" : "no GPU client in backboardd")
    return p.joined(separator: ", ")
}

func batteryLine(_ b: BatteryMetrics) -> String {
    var p: [String] = []
    if let c = b.charging { p.append(c ? "charging" : (b.external == true ? "plugged, not charging" : "on battery")) }
    if let v = b.voltageMv { p.append(String(format: "%.2f V", v / 1000)) }
    if let s = b.source { p.append(s) }
    return p.isEmpty ? "unknown" : p.joined(separator: " | ")
}

// MARK: Control Plane strip

/// Compact, dark, scaled like the Control Plane tiles (`s` is its layout scale).
struct MetricsStrip: View {
    @Environment(AppModel.self) private var model
    var s: CGFloat

    var body: some View {
        let mon = model.monitor
        if mon.state == .ios {
            HStack(spacing: 18 * s) {
                if let m = mon.metrics {
                    cpuCard(m, mon.metricsHistory)
                    gpuCard(m, mon.metricsHistory)
                    batteryCard(m, mon.metricsHistory)
                } else {
                    card { Text("METRICS").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
                        Text(mon.metricsError ?? "waiting for sweetmetrics...").font(.system(size: 18 * s)).foregroundStyle(.orange).lineLimit(2) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6 * s) { c() }
            .padding(14 * s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16 * s))
    }

    private func cpuCard(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        card {
            Text("CPU").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
            ForEach(m.clusters, id: \.id) { c in
                let peak = max(c.maxKhz ?? 0, h.peakKhz(c.id), c.nominalMaxKhz)
                HStack(spacing: 10 * s) {
                    Text(c.name).font(.system(size: 18 * s, weight: .bold)).frame(width: 52 * s, alignment: .leading)
                    FreqBar(fraction: c.curKhz.map { Double($0) / Double(peak) }, color: .blue, height: 10 * s)
                    Text(c.curKhz.map(formatKhz) ?? "unknown").font(.system(size: 18 * s, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(width: 96 * s, alignment: .trailing)
                    Text(c.loadPct.map { String(format: "%.0f%%", $0) } ?? "--").font(.system(size: 16 * s).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44 * s, alignment: .trailing)
                    Sparkline(points: h.cpu(c.id), color: .blue, range: 0...Double(peak)).frame(width: 90 * s, height: 22 * s)
                }
            }
        }
    }

    private func gpuCard(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        card {
            HStack(spacing: 8 * s) {
                Text("GPU").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
                Text(m.gpu.state.uppercased()).font(.system(size: 13 * s, weight: .heavy)).padding(.horizontal, 7 * s).padding(.vertical, 1)
                    .background(gpuStateColor(m.gpu.state).opacity(0.3), in: Capsule()).foregroundStyle(gpuStateColor(m.gpu.state))
                Spacer(minLength: 0)
                RendererBadge(r: m.renderer, size: 13 * s)
            }
            HStack(spacing: 10 * s) {
                FreqBar(fraction: m.gpu.mhz.map { $0 / (m.gpu.maxMhz ?? 710) }, color: .purple, height: 10 * s)
                Text(m.gpu.mhz.map { String(format: "%.0f MHz", $0) } ?? "unknown").font(.system(size: 18 * s, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 92 * s, alignment: .trailing)
                Text(m.gpu.busyPct.map { String(format: "%.0f%%", $0) } ?? "--").font(.system(size: 16 * s).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44 * s, alignment: .trailing)
                Sparkline(points: h.gpu, color: .purple, range: 0...(m.gpu.maxMhz ?? 710)).frame(width: 90 * s, height: 22 * s)
            }
            Text((m.gpu.hasDCVS ? "" : (m.gpu.state == "absent" ? "no GPU driver in this kernel, " : "level/MHz/busy: waiting on the GPU DCVS interface, ")) + rendererDetail(m.renderer))
                .font(.system(size: 13 * s)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func batteryCard(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        card {
            Text("BATTERY  DRAW").font(.system(size: 16 * s, weight: .bold)).foregroundStyle(.secondary)
            HStack(spacing: 10 * s) {
                Text(m.battery.percent.map { String(format: "%.0f%%", $0) } ?? "--").font(.system(size: 30 * s, weight: .heavy, design: .rounded))
                    .foregroundStyle((m.battery.percent ?? 100) < 20 ? .red : .green)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.battery.currentMa.map(formatMa) ?? "mA unknown").font(.system(size: 20 * s, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(batteryLine(m.battery)).font(.system(size: 13 * s)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                Sparkline(points: h.battery, color: .green, zeroLine: true).frame(width: 90 * s, height: 30 * s)
            }
        }
        .frame(width: 330 * s)
    }
}
