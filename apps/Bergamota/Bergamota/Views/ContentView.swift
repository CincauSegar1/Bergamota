import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", log = "Live Log", ci = "CI", boot = "Boot Queue", apps = "Apps", media = "Media", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .log: "text.alignleft"
        case .ci: "hammer"
        case .boot: "bolt.horizontal.circle"
        case .apps: "square.grid.2x2"
        case .media: "photo.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

extension Color {
    /// Bergamota fastboot (ABL fastboot is orange).
    static let lime = Color(red: 0.62, green: 0.88, blue: 0.12)
}

func stateColor(_ s: PhoneState) -> Color {
    switch s {
    case .ios: .green
    case .fastboot: .orange
    case .bergamotaFastboot: .lime
    case .recovery: .purple
    case .android: .teal
    case .iosBooting: .yellow
    case .offline: .gray
    case .unknown: .secondary
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .dashboard
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(item == .boot ? model.queue.pending.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(stateColor(model.monitor.state)).frame(width: 10, height: 10)
                    Text(model.monitor.state.title).font(.callout)
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .log: LogView()
            case .ci: CIView()
            case .boot: BootView()
            case .apps: AppsView()
            case .media: MediaView()
            case .settings: SettingsView()
            }
        }
        .task { if UserDefaults.standard.bool(forKey: "openControlPlane") { openWindow(id: "control-plane") } }
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "control-plane") } label: { Label("Control Plane", systemImage: "rectangle.on.rectangle") }
                    .help("Open the Control Plane window (for a second display)")
            }
        }
    }
}
