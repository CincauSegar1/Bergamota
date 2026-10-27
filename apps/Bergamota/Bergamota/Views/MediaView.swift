import SwiftUI
import AppKit

struct MediaView: View {
    @Environment(AppModel.self) private var model
    @State private var toPhotos = true
    @State private var folder = PhoneTools.defaultDownloads
    @State private var targeted = false
    @State private var message: String?
    @State private var messageOK = true

    private var dest: String { toPhotos ? "photos" : folder }
    private var destValid: Bool { toPhotos || PhoneTools.validDest(folder) }

    var body: some View {
        let t = model.tools
        VStack(spacing: 12) {
            ActivityBannerView()
            if let r = t.disabledReason {
                Label(r, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Destination", selection: $toPhotos) {
                        Text("Camera Roll").tag(true)
                        Text("Phone folder").tag(false)
                    }.pickerStyle(.segmented)
                    if toPhotos {
                        Text("Images are converted to JPEG (sips) into DCIM/100APPLE via tools/sweet-push-photo.sh; videos are copied as VID_*. Other files go to \(PhoneTools.defaultDownloads).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Folder on the phone", text: $folder).textFieldStyle(.roundedBorder)
                        if !destValid { Text("Absolute path under /private/var/mobile/, /var/mobile/, /private/var/tmp/ or /tmp/ (letters, digits, / _ . - only).").font(.caption).foregroundStyle(.red) }
                    }
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.arrow.down").font(.system(size: 34))
                        Text("Drop images, videos or files here").font(.headline)
                        Button("Choose files...") { chooseFiles() }.disabled(!t.iosUp || t.busy || !destValid)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8])))
                    .dropDestination(for: URL.self) { urls, _ in
                        let files = urls.filter(\.isFileURL).map(\.path)
                        guard !files.isEmpty, destValid else { return false }
                        send(files); return true
                    } isTargeted: { targeted = $0 }
                    if let n = t.uploadingCount { HStack { ProgressView().controlSize(.small); Text("Uploading \(n) file(s)...") } }
                    if let m = message { Label(m, systemImage: messageOK ? "checkmark.circle" : "xmark.octagon").foregroundStyle(messageOK ? .green : .red) }
                    Label("Photos may need a relaunch (or a reboot) to show new pictures.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 400)
                VStack(alignment: .leading) {
                    Text("Recent uploads").font(.headline)
                    List(t.uploads) { u in
                        HStack {
                            Image(systemName: u.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(u.ok ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(u.name)
                                Text(u.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(u.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .overlay { if t.uploads.isEmpty { ContentUnavailableView("No uploads yet", systemImage: "tray") } }
                }
            }
        }
        .padding(12)
        .navigationTitle("Media")
    }

    private func send(_ files: [String]) {
        let d = dest
        Task { let r = await model.tools.upload(files, dest: d); messageOK = r.0; message = r.1 }
    }
    private func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { send(p.urls.map(\.path)) }
    }
}
