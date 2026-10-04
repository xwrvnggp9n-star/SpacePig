import AppKit
import SwiftUI

@MainActor
@Observable
final class CleanupModel {
    var targets: [CleanupTarget] = []
    var selected: Set<String> = []
    var loading = false
    var running = false
    var loadError: String?
    var report: [CleanupTargetResult]?
    var runError: String?
    /// Age filter per target in days (0 = any age).
    var ages: [String: Int] = [:]
    /// Targets being re-measured after an age change.
    var measuring: Set<String> = []
    @ObservationIgnored private var measureTasks: [String: Task<Void, Never>] = [:]

    func age(_ id: String) -> Int { ages[id] ?? 0 }

    /// Changes a target's age filter and re-measures what it would free.
    func setAge(_ days: Int, for target: CleanupTarget, helper: HelperClient) {
        ages[target.id] = days
        measureTasks[target.id]?.cancel()
        measuring.insert(target.id)
        let id = target.id
        measureTasks[id] = Task {
            let bytes: UInt64?
            if target.executor == .root {
                bytes = (try? await helper.rootTargetItems(id: id, olderThanDays: days))?.reduce(0) { $0 + $1.bytes }
            } else {
                bytes = await Task.detached(priority: .userInitiated) { UserCleanup.measure(id: id, olderThanDays: days) }.value
            }
            guard !Task.isCancelled else { return }
            if let i = targets.firstIndex(where: { $0.id == id }) { targets[i].estimatedBytes = bytes }
            measuring.remove(id)
        }
    }

    /// Items a target would remove with its current age filter.
    func items(for target: CleanupTarget, helper: HelperClient) async throws -> [SafeDeleter.Item] {
        let days = age(target.id)
        if target.executor == .root { return try await helper.rootTargetItems(id: target.id, olderThanDays: days) }
        let id = target.id
        return await Task.detached(priority: .userInitiated) { UserCleanup.items(id: id, olderThanDays: days) }.value
    }

    func load(helper: HelperClient) async {
        loading = true
        loadError = nil
        defer { loading = false }
        async let user = Task.detached(priority: .userInitiated) { UserCleanup.list() }.value
        var root: [CleanupTarget] = []
        if helper.isReady {
            do { root = try await helper.rootTargets() } catch { loadError = error.localizedDescription }
        }
        let all = await user + root
        let keepSelection = !targets.isEmpty
        targets = all
        if !keepSelection { selected = Set(all.filter(\.defaultSelected).map(\.id)) }
        selected.formIntersection(Set(all.map(\.id)))
        // Re-apply any age filters the user set.
        for t in all where age(t.id) > 0 { setAge(age(t.id), for: t, helper: helper) }
    }

    var groups: [(String, [CleanupTarget])] {
        let order = ["Caches", "Logs", "Developer", "Package managers", "System caches", "System logs",
                     "Time Machine local snapshots", "Leftovers", "iOS backups", "Trash"]
        let grouped = Dictionary(grouping: targets, by: \.group)
        return grouped.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { ($0, grouped[$0]!.sorted { ($0.estimatedBytes ?? 0) > ($1.estimatedBytes ?? 0) }) }
    }

    var selectedTargets: [CleanupTarget] { targets.filter { selected.contains($0.id) } }
    var selectedBytes: UInt64 { selectedTargets.reduce(0) { $0 + ($1.estimatedBytes ?? 0) } }
    var selectedHasUnknownSize: Bool { selectedTargets.contains { $0.estimatedBytes == nil } }

    func run(helper: HelperClient) async {
        running = true
        runError = nil
        defer { running = false }
        let chosen = selectedTargets
        let userIDs = chosen.filter { $0.executor == .user }.map(\.id)
        let rootIDs = chosen.filter { $0.executor == .root }.map(\.id)
        // Ask for the administrator password first; cancelling it removes nothing.
        var auth: AdminAuthorization?
        if !rootIDs.isEmpty {
            do {
                auth = try await helper.authorizeCleanup()
            } catch {
                runError = error.localizedDescription
                return
            }
        }
        var results: [CleanupTargetResult] = []
        let ages = self.ages
        results += await Task.detached(priority: .userInitiated) {
            userIDs.map { UserCleanup.run(id: $0, olderThanDays: ages[$0] ?? 0) }
        }.value
        if let auth {
            do {
                results += try await helper.runRootCleanup(ids: rootIDs, ages: ages.filter { rootIDs.contains($0.key) },
                                                           auth: auth).results
            } catch {
                runError = error.localizedDescription
            }
        }
        report = results
        await load(helper: helper)
    }
}

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var cleanup = CleanupModel()
    @State private var confirm = false
    @State private var detailsTarget: CleanupTarget?

    var body: some View {
        VStack(spacing: 0) {
            if cleanup.loading && cleanup.targets.isEmpty {
                ProgressView("Measuring cleanup targets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .navigationTitle("Clean Up")
        .task { if cleanup.targets.isEmpty { await cleanup.load(helper: model.helper) } }
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button("Clean Up", role: .destructive) { Task { await cleanup.run(helper: model.helper) } }
        } message: {
            Text(confirmMessage)
        }
        .alert("Cleanup did not run", isPresented: Binding(get: { cleanup.report == nil && cleanup.runError != nil },
                                                           set: { if !$0 { cleanup.runError = nil } })) {
            Button("OK") { cleanup.runError = nil }
        } message: {
            Text(cleanup.runError ?? "")
        }
        .sheet(item: $detailsTarget) { t in
            CleanupDetailsSheet(target: t, cleanup: cleanup)
        }
        .sheet(isPresented: Binding(get: { cleanup.report != nil }, set: { if !$0 { cleanup.report = nil } })) {
            ReportSheet(results: cleanup.report ?? [], targets: cleanup.targets, error: cleanup.runError) {
                cleanup.report = nil
                model.dataIsStale = true
            }
        }
    }

    private var list: some View {
        List {
            if !model.helper.isReady {
                Text("System-wide targets appear once the helper is installed. See Overview.")
                    .foregroundStyle(.secondary)
            }
            if let e = cleanup.loadError { Text(e).foregroundStyle(.red) }
            ForEach(cleanup.groups, id: \.0) { group, items in
                Section(group) {
                    ForEach(items) { t in
                        TargetRow(target: t, isOn: binding(t.id), cleanup: cleanup) { detailsTarget = t }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { cleanup.selected.contains(id) },
                set: { if $0 { cleanup.selected.insert(id) } else { cleanup.selected.remove(id) } })
    }

    private var footer: some View {
        HStack {
            Button("Select None") { cleanup.selected = [] }
            Button("Defaults") { cleanup.selected = Set(cleanup.targets.filter(\.defaultSelected).map(\.id)) }
            Button { Task { await cleanup.load(helper: model.helper) } } label: { Label("Measure Again", systemImage: "arrow.clockwise") }
                .disabled(cleanup.loading || cleanup.running)
            Spacer()
            if cleanup.running { ProgressView().controlSize(.small); Text("Cleaning up…") }
            Text("\(cleanup.selected.count) selected, about \(ByteFormat.string(cleanup.selectedBytes))\(cleanup.selectedHasUnknownSize ? " plus items of unknown size" : "")")
                .monospacedDigit()
            Button("Clean Up…") { confirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(cleanup.selected.isEmpty || cleanup.running || cleanup.loading)
        }
        .padding(12)
    }

    private var confirmTitle: String {
        "Remove \(cleanup.selected.count) item\(cleanup.selected.count == 1 ? "" : "s")?"
    }

    private var confirmMessage: String {
        var s = "About \(ByteFormat.string(cleanup.selectedBytes)) will be deleted. This skips the Trash and cannot be undone."
        if cleanup.selectedTargets.contains(where: { $0.executor == .root }) {
            s += " System-wide items need your administrator password."
        }
        return s
    }
}

struct TargetRow: View {
    @Environment(AppModel.self) private var model
    let target: CleanupTarget
    @Binding var isOn: Bool
    let cleanup: CleanupModel
    let showDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $isOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(target.title)
                            if target.executor == .root { Badge(text: "admin", color: .purple) }
                        }
                        Text(target.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                if cleanup.measuring.contains(target.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text(target.estimatedBytes.map(ByteFormat.string) ?? "size unknown")
                        .monospacedDigit()
                        .foregroundStyle(target.estimatedBytes == nil ? .secondary : .primary)
                }
            }
            HStack(spacing: 14) {
                if target.supportsAge {
                    Text("Not modified in").font(.callout).foregroundStyle(.secondary)
                    Picker("Not modified in", selection: Binding(
                        get: { cleanup.age(target.id) },
                        set: { cleanup.setAge($0, for: target, helper: model.helper) })) {
                        Text("Any age").tag(0)
                        ForEach(CleanupAge.choices.filter { $0 > 0 }, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                    .help("Only remove files that haven't been modified in this many days")
                }
                if hasDetails {
                    Button("Details…", action: showDetails)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 3)
    }

    private var hasDetails: Bool {
        target.command != nil || !target.preview.isEmpty || target.estimatedBytes != nil
    }
}

/// Everything a target would remove, with sizes and dates.
struct CleanupDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: CleanupTarget
    let cleanup: CleanupModel

    @State private var items: [SafeDeleter.Item]?
    @State private var error: String?
    @State private var sortOrder = [KeyPathComparator(\SafeDeleter.Item.bytes, order: .reverse)]
    @State private var selection: Set<String> = []

    /// User targets that run a tool (brew, npm, simctl) rather than delete listed items.
    private var isCommand: Bool { target.executor == .user && target.command != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.title).font(.title3).bold()
            Text(summary).foregroundStyle(.secondary)
            if let c = target.command {
                Text("Runs: \(c)").font(.callout.monospaced()).textSelection(.enabled)
            }
            if isCommand {
                commandPreview
            } else if items != nil {
                Table(sortedItems, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Item", value: \.path) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                            Text(displayPath(item.path)).lineLimit(1).truncationMode(.head).help(item.path)
                        }
                    }
                    .width(min: 200, ideal: 320)
                    TableColumn("Size", value: \.bytes) { item in
                        Text(ByteFormat.string(item.bytes)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90, max: 110)
                    TableColumn("Files", value: \.files) { item in
                        Text(item.files.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 70, max: 90)
                    TableColumn("Last modified", value: \.sortDate) { item in
                        Text(item.newestModified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 170, ideal: 180)
                }
                .contextMenu(forSelectionType: String.self) { paths in
                    Button("Reveal in Finder") { reveal(paths) }
                } primaryAction: { paths in reveal(paths) }
            } else if let error {
                Text(error).foregroundStyle(.red)
                Spacer()
            } else {
                ProgressView("Listing items…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if !selection.isEmpty { Button("Reveal in Finder") { reveal(selection) } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 620)
        .task(id: cleanup.age(target.id)) { await load() }
    }

    private var summary: String {
        let age = cleanup.age(target.id)
        let ageText = age > 0 ? " Only files not modified in the last \(age) days are included; folders are removed once they're empty." : ""
        if let items {
            let total = items.reduce(0) { $0 + $1.bytes }
            let files = items.reduce(0) { $0 + $1.files }
            return "\(items.count.formatted()) items, \(files.formatted()) files, \(ByteFormat.string(total)).\(ageText) Double-click a row to show it in Finder."
        }
        return target.detail + ageText
    }

    private var sortedItems: [SafeDeleter.Item] { (items ?? []).sorted(using: sortOrder) }

    @ViewBuilder private var commandPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if target.preview.isEmpty {
                    Text("This target runs the command above; the tool decides what to remove.").foregroundStyle(.secondary)
                }
                ForEach(target.preview, id: \.self) { Text($0).font(.callout.monospaced()) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func load() async {
        guard !isCommand else { return }
        items = nil
        do { items = try await cleanup.items(for: target, helper: model.helper) } catch { self.error = error.localizedDescription }
    }

    /// Path relative to the folder the items share, so the name shows instead of the prefix.
    private func displayPath(_ p: String) -> String {
        guard let base = commonFolder, p.hasPrefix(base + "/") else {
            let home = NSHomeDirectory()
            return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
        }
        return String(p.dropFirst(base.count + 1))
    }

    private var commonFolder: String? {
        let folders = Set((items ?? []).map { ($0.path as NSString).deletingLastPathComponent })
        if folders.count == 1 { return folders.first }
        // Several folders (device support for iOS, watchOS...): keep each folder's own name.
        let parents = Set(folders.map { ($0 as NSString).deletingLastPathComponent })
        return parents.count == 1 ? parents.first : nil
    }

    private func reveal(_ paths: Set<String>) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }
}

extension SafeDeleter.Item: Identifiable {
    var id: String { path }
    var sortDate: Date { newestModified ?? .distantPast }
}

struct ReportSheet: View {
    let results: [CleanupTargetResult]
    let targets: [CleanupTarget]
    let error: String?
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup finished").font(.title2).bold()
            Text("Freed about \(ByteFormat.string(results.reduce(0) { $0 + $1.freedBytes })) in files the app could measure. Commands report their own results below.")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            List(results, id: \.targetID) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: r.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.failed == 0 ? .green : .orange)
                        Text(targets.first { $0.id == r.targetID }?.title ?? r.targetID)
                        Spacer()
                        if r.freedBytes > 0 { Text(ByteFormat.string(r.freedBytes)).monospacedDigit() }
                    }
                    if r.failed > 0 { Text("\(r.failed) item(s) could not be removed.").font(.caption).foregroundStyle(.orange) }
                    ForEach(r.failures.prefix(5), id: \.self) { f in
                        Text("\(f.path): \(f.message ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let o = r.output, !o.isEmpty {
                        Text(o.suffix(600)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                    }
                }
            }
            .frame(minHeight: 260)
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}
