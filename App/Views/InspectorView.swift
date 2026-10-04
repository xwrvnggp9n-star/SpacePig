import AppKit
import SwiftUI

enum Inspector {
    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let item: BrowserItem?
    let browser: Browser
    @State private var confirmTrash = false
    @State private var trashError: String?

    var body: some View {
        if let item {
            let d = browser.details(for: item)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(d.title).font(.title3).bold().textSelection(.enabled)
                    if let p = d.displayPath {
                        Text(p).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(ByteFormat.string(d.size)).font(.largeTitle).monospacedDigit()
                    VStack(alignment: .leading, spacing: 4) {
                        if let files = d.files, files > 0 { row("Files", files.formatted()) }
                        if let u = d.unsharedSize {
                            row("Not shared with clones", ByteFormat.string(u))
                        }
                        if let c = d.category { row("Category", c.title) }
                    }
                    if let u = d.unsharedSize, u < d.size {
                        Text("Some files here are APFS clones that share blocks with copies elsewhere. Deleting them frees about \(ByteFormat.string(u)) at most.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    flagText(d.flags)
                    if let info = d.info {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                if d.infoIsInherited { Text("Inside:").font(.caption).foregroundStyle(.secondary) }
                                Text(info)
                                if let s = d.safety {
                                    Label(s.title, systemImage: safetyIcon(s))
                                        .foregroundStyle(safetyColor(s)).font(.callout)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }
                    if let note = d.note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                    if let p = d.displayPath {
                        HStack {
                            Button("Reveal in Finder") { Inspector.reveal(p) }
                            if canTrash(item: item, path: p, details: d) {
                                Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                            }
                        }
                        .confirmationDialog("Move “\(item.name)” to the Trash?", isPresented: $confirmTrash) {
                            Button("Move to Trash", role: .destructive) { trash(p, expectDirectory: d.isDirectory) }
                        } message: {
                            Text("This moves the whole item (\(ByteFormat.string(d.fullSize ?? d.size)) at the last scan). The space comes back once you empty the Trash.")
                        }
                    }
                    if let trashError { Text(trashError).foregroundStyle(.red).font(.callout) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select an item", systemImage: "info.circle",
                                   description: Text("Double-click a folder to open it."))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    @ViewBuilder private func flagText(_ f: NodeFlags) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if f.contains(.unreadable) {
                Label("Could not be read. Its contents are not counted.", systemImage: "eye.slash").foregroundStyle(.orange)
            }
            if f.contains(.dataless) {
                Label("Stored in the cloud. Takes almost no space here.", systemImage: "icloud")
            }
            if f.contains(.otherDevice) {
                Label("A different volume mounted here. Not counted.", systemImage: "externaldrive")
            }
            if f.contains(.purgeable) {
                Label("Purgeable: macOS may delete it when space runs low.", systemImage: "leaf")
            }
            if f.contains(.aggregate) {
                Label("Files under 1 MB in this folder, grouped.", systemImage: "doc.on.doc")
            }
        }
        .font(.callout)
    }

    private func safetyIcon(_ s: Safety) -> String {
        switch s {
        case .system: return "lock"
        case .appData: return "app.badge"
        case .userData: return "person"
        case .rebuilds, .safe: return "checkmark.circle"
        }
    }

    private func safetyColor(_ s: Safety) -> Color {
        switch s {
        case .system: return .secondary
        case .appData, .userData: return .orange
        case .rebuilds, .safe: return .green
        }
    }

    private func canTrash(item: BrowserItem, path: String, details: Browser.Details) -> Bool {
        guard case .tree(.data, _) = item.kind, !item.flags.contains(.aggregate) else { return false }
        guard details.safety != .system else { return false }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") || path.hasPrefix("/Applications/") else { return false }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    private func trash(_ path: String, expectDirectory: Bool) {
        // The scan may be old: refuse if the path is gone or is now a different kind of item.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue == expectDirectory else {
            trashError = "This item changed since the scan. Scan again first."
            return
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            model.dataIsStale = true
            trashError = nil
        } catch {
            trashError = error.localizedDescription
        }
    }
}
