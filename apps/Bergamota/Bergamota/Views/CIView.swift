import SwiftUI

struct CIView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false

    var body: some View {
        let ci = model.ci
        VStack(spacing: 0) {
            HStack {
                Text("xnu.yml on main, ios18, ci-cache").font(.headline)
                Spacer()
                if ci.loading { ProgressView().controlSize(.small) }
                if let t = ci.lastRefresh { Text("updated \(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                Button { Task { await ci.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(ci.loading)
            }
            .padding(12)
            if let e = ci.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).textSelection(.enabled)
            }
            Divider()
            List(ci.runs) { run in
                HStack(spacing: 12) {
                    statusIcon(run).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(run.headBranch).font(.body.bold())
                            Text(run.shortSha).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(run.displayTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(run.createdAt.formatted(.relative(presentation: .named))).font(.callout)
                        Text(run.duration.map { formatUptime($0) } ?? "-").font(.caption).foregroundStyle(.secondary)
                    }
                    downloadControl(run)
                    if let u = run.url, let url = URL(string: u) { Link(destination: url) { Image(systemName: "safari") }.help("Open on GitHub") }
                }
                .padding(.vertical, 3)
            }
            .overlay { if ci.runs.isEmpty && !ci.loading { ContentUnavailableView("No runs loaded", systemImage: "hammer", description: Text("Press Refresh.")) } }
            Divider()
            DisclosureGroup("Download log", isExpanded: $showLog) {
                ScrollView { Text(ci.downloadLog.isEmpty ? "(empty)" : ci.downloadLog).font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: 110)
            }
            .padding(10)
        }
        .navigationTitle("CI")
        .task { if model.ci.runs.isEmpty { await model.ci.refresh() } }
    }

    @ViewBuilder private func statusIcon(_ r: CIRun) -> some View {
        if !r.isDone { Image(systemName: "circle.dotted").foregroundStyle(.orange).symbolEffect(.pulse) }
        else if r.conclusion == "success" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        else if r.conclusion == "cancelled" || r.conclusion == "skipped" { Image(systemName: "slash.circle").foregroundStyle(.secondary) }
        else { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
    }

    @ViewBuilder private func downloadControl(_ r: CIRun) -> some View {
        let ci = model.ci
        switch ci.downloads[r.id] {
        case .running: ProgressView().controlSize(.small).frame(width: 130)
        case .done(let d): Label("Saved", systemImage: "checkmark").foregroundStyle(.green).help(d).frame(width: 130)
        case .failed(let e): Button("Retry download") { Task { await ci.downloadKernel(r); model.build.rescan() } }.help(e).foregroundStyle(.red).frame(width: 130)
        case nil:
            if ci.isDownloaded(r) { Label("Downloaded", systemImage: "checkmark.circle").foregroundStyle(.secondary).frame(width: 130) }
            else {
                Button { Task { await ci.downloadKernel(r); model.build.rescan() } } label: { Label("Download kernel", systemImage: "arrow.down.circle") }
                    .disabled(r.conclusion != "success").frame(width: 130)
            }
        }
    }
}
