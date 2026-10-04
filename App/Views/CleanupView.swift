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
        targets = all
        selected = Set(all.filter(\.defaultSelected).map(\.id))
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
        var results: [CleanupTargetResult] = []
        results += await Task.detached(priority: .userInitiated) { userIDs.map { UserCleanup.run(id: $0) } }.value
        if !rootIDs.isEmpty {
            do {
                results += try await helper.runRootCleanup(ids: rootIDs).results
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
                    ForEach(items) { t in TargetRow(target: t, isOn: binding(t.id)) }
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
    let target: CleanupTarget
    @Binding var isOn: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                Text(target.estimatedBytes.map(ByteFormat.string) ?? "size unknown")
                    .monospacedDigit()
                    .foregroundStyle(target.estimatedBytes == nil ? .secondary : .primary)
            }
            if !target.preview.isEmpty || target.command != nil {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let c = target.command { Text("Runs: \(c)").font(.caption.monospaced()) }
                        ForEach(target.preview, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Details").font(.caption)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 3)
    }
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
