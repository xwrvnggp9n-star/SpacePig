import SwiftUI

extension StorageCategory {
    var color: Color {
        switch self {
        case .macOS: return Color(red: 0.55, green: 0.56, blue: 0.60)
        case .systemData: return Color(red: 0.40, green: 0.41, blue: 0.45)
        case .applications: return .red
        case .documents: return .orange
        case .iCloudDrive: return .cyan
        case .photos: return .yellow
        case .messages: return .green
        case .mail: return .blue
        case .music: return .pink
        case .tv: return .indigo
        case .podcasts: return .purple
        case .books: return .brown
        case .musicCreation: return .mint
        case .developer: return .teal
        case .iOSFiles: return Color(red: 0.2, green: 0.5, blue: 0.9)
        case .trash: return Color(red: 0.7, green: 0.5, blue: 0.3)
        case .otherUsers: return Color(red: 0.6, green: 0.4, blue: 0.7)
        }
    }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HelperStatusCard()
                if !model.hasFullDiskAccess { FullDiskAccessCard() }
                scanCard
                if let v = model.volumes { usageCard(v) }
                if model.index != nil { categoryTable }
                if let v = model.volumes { volumeTable(v) }
                if model.index != nil { notes }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var scanCard: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text(model.scanMessage).monospacedDigit()
                    Spacer()
                    Button("Stop") { model.cancelScan() }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let d = model.data {
                            Text("Last scan \(d.date.formatted(date: .omitted, time: .shortened)), \(d.source.rawValue). \(d.tree.count.formatted()) items.")
                        } else {
                            Text("No scan yet.")
                        }
                        if let err = model.scanError { Text(err).foregroundStyle(.red) }
                        if model.dataIsStale { Text("You moved items to the Trash. Scan again to update the numbers.").foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button(model.data == nil ? "Scan Disk" : "Scan Again") { model.scanAll() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(6)
        }
    }

    private func usageCard(_ v: VolumeReport) -> some View {
        GroupBox("Disk") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(ByteFormat.string(v.used)) used of \(ByteFormat.string(v.capacity)), \(ByteFormat.string(v.free)) free")
                    .font(.title3)
                if model.index != nil {
                    stackedBar(v)
                    legend
                }
            }
            .padding(6)
        }
    }

    private var shownCategories: [StorageCategory] {
        StorageCategory.allCases.filter { model.total(for: $0) > 0 }.sorted { model.total(for: $0) > model.total(for: $1) }
    }

    private func stackedBar(_ v: VolumeReport) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(shownCategories) { c in
                    let w = geo.size.width * CGFloat(Double(model.total(for: c)) / Double(max(v.capacity, 1)))
                    Rectangle().fill(c.color).frame(width: max(w, 0))
                        .help("\(c.title): \(ByteFormat.string(model.total(for: c)))")
                        .onTapGesture { selection = .category(c) }
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 22)
    }

    private var legend: some View {
        FlowLayout(spacing: 12) {
            ForEach(shownCategories) { c in
                HStack(spacing: 5) {
                    Circle().fill(c.color).frame(width: 9, height: 9)
                    Text(c.title).font(.caption)
                }
            }
        }
    }

    private var categoryTable: some View {
        GroupBox("Categories, as this app reconstructs them") {
            VStack(spacing: 0) {
                ForEach(shownCategories) { c in
                    Button { selection = .category(c) } label: {
                        HStack {
                            Label(c.title, systemImage: c.symbol)
                            Spacer()
                            Text(ByteFormat.string(model.total(for: c))).monospacedDigit()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(6)
        }
    }

    private func volumeTable(_ v: VolumeReport) -> some View {
        GroupBox("APFS volumes in container \(v.containerDevice)") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Volume").bold(); Text("Role").bold(); Text("Device").bold()
                    Text("Used").bold().gridColumnAlignment(.trailing)
                }
                Divider()
                ForEach(v.volumes.sorted { $0.consumed > $1.consumed }) { vol in
                    GridRow {
                        Text(vol.name)
                        Text(vol.roleSummary).foregroundStyle(.secondary)
                        Text(vol.device).foregroundStyle(.secondary).monospaced()
                        Text(ByteFormat.string(vol.consumed)).monospacedDigit()
                    }
                }
            }
            .padding(6)
        }
    }

    private var notes: some View {
        GroupBox("How the numbers fit") {
            VStack(alignment: .leading, spacing: 8) {
                if let u = model.dataUnexplained {
                    Text("Data volume used \(ByteFormat.string(model.volumes?.data?.consumed ?? 0)); files the scan found \(ByteFormat.string(model.data?.tree.total[0] ?? 0)); difference \(ByteFormat.string(signed: u)). A positive difference is APFS metadata, snapshots and unreadable folders. A negative one means cloned files were counted more than once.")
                }
                if let v = model.volumes {
                    if !v.snapshotNames.isEmpty {
                        Text("\(v.snapshotNames.count) local snapshot(s) on the Data volume. Their size can't be measured directly; it is part of the difference above.")
                    }
                    Text("Swap in use \(ByteFormat.string(v.swapUsed)) of \(ByteFormat.string(v.swapTotal)). Sleep image \(ByteFormat.string(v.sleepImage)).")
                    if v.purgeable > 0 {
                        Text("About \(ByteFormat.string(v.purgeable)) is purgeable: macOS can free it on its own when space runs low. Like System Settings, the Messages total leaves out attachments kept in iCloud.")
                    }
                }
                Text("Apple doesn't publish how System Settings assigns files to categories. These totals come from the rules bundled with the app and will differ somewhat from System Settings.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(6)
        }
    }
}

struct HelperStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                actions
            }
            .padding(6)
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.helper.state {
        case .notInstalled:
            Button("Install Helper") { Task { await model.helper.install() } }.buttonStyle(.borderedProminent)
        case .needsApproval:
            VStack(alignment: .trailing) {
                Button("Open Login Items") { model.helper.openApprovalSettings() }.buttonStyle(.borderedProminent)
                Button("Check Again") { Task { await model.helper.refresh() } }
            }
        case .failed:
            VStack(alignment: .trailing) {
                Button("Reinstall Helper") { Task { await model.helper.reinstall() } }
                Button("Check Again") { Task { await model.helper.refresh() } }
            }
        case .ready:
            Menu("Helper") {
                Button("Check Again") { Task { await model.helper.refresh() } }
                Button("Reinstall Helper") { Task { await model.helper.reinstall() } }
                Divider()
                Button("Uninstall Helper") { Task { await model.helper.uninstall() } }
            }
            .fixedSize()
        case .checking, .wrongLocation:
            EmptyView()
        }
    }

    private var icon: String {
        switch model.helper.state {
        case .ready: return "checkmark.shield.fill"
        case .failed, .wrongLocation: return "exclamationmark.triangle.fill"
        default: return "lock.shield"
        }
    }

    private var color: Color {
        switch model.helper.state {
        case .ready: return .green
        case .failed, .wrongLocation: return .orange
        default: return .secondary
        }
    }

    private var title: String {
        switch model.helper.state {
        case .checking: return "Checking the helper…"
        case .wrongLocation: return "Move SpacePig to Applications"
        case .notInstalled: return "Limited mode"
        case .needsApproval: return "Approve the helper"
        case .ready(let v): return "Helper running (\(v))"
        case .failed: return "Helper problem"
        }
    }

    private var message: String {
        switch model.helper.state {
        case .checking: return ""
        case .wrongLocation:
            return "The app is running from a disk image or a quarantined copy. Drag it to /Applications and open it from there before installing the helper."
        case .notInstalled:
            return "Without the helper the app sees only what your account can read, so other users' folders and parts of /private and /Library show up as unreadable. The helper is a small background tool that scans as root. Only administrators can use it."
        case .needsApproval:
            return "Turn on SpacePig under \"Allow in the Background\" in System Settings > General > Login Items & Extensions, then click Check Again."
        case .ready:
            return "Scans run as root. Cleanups that touch system folders ask for an administrator password each time."
        case .failed(let s):
            return s
        }
    }
}

struct FullDiskAccessCard: View {
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full Disk Access is off").font(.headline)
                    Text("macOS hides Mail, Messages, Safari and other app data from every app without Full Disk Access, even when it runs as root. Turn it on for SpacePig (and for SpacePigHelper if it appears), then quit and reopen the app.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(6)
        }
    }
}

/// Wraps subviews onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + 6; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + 6; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
