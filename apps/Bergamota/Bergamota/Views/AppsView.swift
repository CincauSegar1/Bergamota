import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var message: String?
    @State private var messageOK = true
    @State private var confirmRemove: InstalledApp?

    var body: some View {
        let t = model.tools
        VStack(spacing: 0) {
            ActivityBannerView().padding(12)
            if let r = t.disabledReason {
                Label(r, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 34))
                        Text("Drop an .ipa here").font(.headline)
                        Text("Decrypted iOS 16 arm64 only. Runs tools/sweet-install-ipa.sh (re-sign ad-hoc, copy to /Applications, register).")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Choose IPA...") { chooseIPA() }.disabled(!t.iosUp || t.busy)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8])))
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let u = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { show(false, "Not an .ipa"); return false }
                        install(u.path); return true
                    } isTargeted: { targeted = $0 }
                    if let m = message { Label(m, systemImage: messageOK ? "checkmark.circle" : "xmark.octagon").foregroundStyle(messageOK ? .green : .red).frame(maxWidth: .infinity, alignment: .leading) }
                    if t.installing != nil { HStack { ProgressView().controlSize(.small); Text(t.installing ?? "") } }
                }
                .frame(width: 360)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Installed apps (/Applications)").font(.headline)
                        Spacer()
                        if t.listing { ProgressView().controlSize(.small) }
                        Button { Task { await t.refreshInstalled() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!t.iosUp || t.listing)
                    }
                    if let e = t.listError, t.installed.isEmpty { Text(e).foregroundStyle(.orange).font(.caption) }
                    List(t.installed) { app in
                        HStack {
                            Image(systemName: app.ours ? "person.crop.square.fill" : "apple.logo").foregroundStyle(app.ours ? .green : .secondary)
                            Text(app.name)
                            if app.ours { Text(app.recorded ? "sideloaded" : "third-party (guess)").font(.caption).foregroundStyle(.secondary) }
                            else { Text("system").font(.caption).foregroundStyle(.tertiary) }
                            Spacer()
                            if app.ours { Button("Uninstall") { confirmRemove = app }.controlSize(.small).disabled(!t.iosUp || t.busy) }
                        }
                    }
                    .overlay { if t.installed.isEmpty && !t.listing { ContentUnavailableView("No list yet", systemImage: "square.grid.2x2", description: Text("Refresh when iOS is up.")) } }
                }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(t.output.isEmpty ? "Install output appears here." : t.output).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t.output.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8).textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 170).background(Color(nsColor: .textBackgroundColor))
                .onChange(of: t.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .navigationTitle("Apps")
        .task { if model.tools.iosUp && model.tools.installed.isEmpty { await model.tools.refreshInstalled() } }
        .confirmationDialog("Uninstall \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Uninstall", role: .destructive) { if let a = confirmRemove { Task { let r = await t.uninstall(a); show(r.0, r.1) } } }
        }
    }

    private func show(_ ok: Bool, _ m: String) { messageOK = ok; message = m }
    private func install(_ path: String) { Task { let r = await model.tools.installIPA(path); show(r.0, r.1) } }
    private func chooseIPA() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        if p.runModal() == .OK, let u = p.url { install(u.path) }
    }
}
