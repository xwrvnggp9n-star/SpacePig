import SwiftUI

@main
struct SystemDataLensApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { await model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") { model.scanAll() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
            }
        }
    }
}

enum SidebarItem: Hashable {
    case overview
    case category(StorageCategory)
    case raw(TreeID)
    case cleanup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Overview", systemImage: "internaldrive").tag(SidebarItem.overview)
                }
                Section("Categories") {
                    ForEach(sidebarCategories) { c in
                        HStack {
                            Label(c.title, systemImage: c.symbol)
                            Spacer()
                            if model.index != nil {
                                Text(ByteFormat.string(model.total(for: c)))
                                    .foregroundStyle(.secondary).monospacedDigit().font(.callout)
                            }
                        }
                        .tag(SidebarItem.category(c))
                    }
                }
                Section("Browse") {
                    Label("Data volume", systemImage: "folder").tag(SidebarItem.raw(.data))
                    Label("System volume", systemImage: "lock.laptopcomputer").tag(SidebarItem.raw(.system))
                    if model.preboot != nil {
                        Label("Preboot volume", systemImage: "bolt.horizontal").tag(SidebarItem.raw(.preboot))
                    }
                }
                Section {
                    Label("Clean Up", systemImage: "sparkles").tag(SidebarItem.cleanup)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            switch selection {
            case .overview, .none:
                OverviewView(selection: $selection)
            case .category(let c):
                BrowserView(scope: .category(c)).id(c)
            case .raw(let t):
                BrowserView(scope: .raw(t)).id(t)
            case .cleanup:
                CleanupView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancelScan() }
                } else {
                    Button { model.scanAll() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                        .help("Scan the disk (⌘R)")
                }
            }
        }
    }

    private var sidebarCategories: [StorageCategory] {
        let always: Set<StorageCategory> = [.macOS, .systemData]
        let all = StorageCategory.allCases.filter { always.contains($0) || model.total(for: $0) > 0 || model.index == nil }
        guard model.index != nil else { return all }
        return all.sorted { model.total(for: $0) > model.total(for: $1) }
    }
}
