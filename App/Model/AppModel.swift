import Foundation
import Observation

/// A scanned tree plus how it was obtained.
struct ScannedTree {
    enum Source: String { case helper = "root helper", user = "this user only" }
    var tree: FlatTree
    var source: Source
    var date: Date
}

@MainActor
@Observable
final class AppModel {
    let helper = HelperClient()

    var volumes: VolumeReport?
    var data: ScannedTree?
    var system: ScannedTree?
    var preboot: ScannedTree?
    var index: CategoryIndex?

    var isScanning = false
    var scanMessage = ""
    var scanError: String?
    var hasFullDiskAccess = true

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// The user's home as a path on the Data volume, e.g. "/Users/sandy".
    nonisolated static var homeRelative: String { NSHomeDirectory() }
    static let dataRoot = "/System/Volumes/Data"

    func start() async {
        await helper.refresh()
        hasFullDiskAccess = AppModel.checkFullDiskAccess()
        if volumes == nil { volumes = await Task.detached { VolumeReport.load() }.value }
    }

    /// TCC-protected folders that only open with Full Disk Access.
    nonisolated static func checkFullDiskAccess() -> Bool {
        let probes = ["/Library/Application Support/com.apple.TCC/TCC.db",
                      NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if FileManager.default.isReadableFile(atPath: p), (try? Data(contentsOf: URL(fileURLWithPath: p), options: .mappedIfSafe)) != nil {
                return true
            }
            return false
        }
        return true
    }

    func scanAll() {
        guard !isScanning else { return }
        scanTask = Task { await runScan() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func runScan() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false; scanMessage = "" }

        scanMessage = "Reading volumes…"
        volumes = await Task.detached { VolumeReport.load() }.value
        hasFullDiskAccess = AppModel.checkFullDiskAccess()

        do {
            // Sealed system volume: world-readable, scanned by the app itself.
            scanMessage = "Scanning the macOS system volume…"
            let sys = try await localScan(root: "/", label: "macOS system volume")
            system = ScannedTree(tree: sys, source: .user, date: Date())

            // Data volume: root helper if available, otherwise this user's view.
            let dataTree: FlatTree
            let source: ScannedTree.Source
            if helper.isReady {
                dataTree = try await helper.scan(root: AppModel.dataRoot) { [weak self] s in
                    self?.scanMessage = "Scanning the Data volume as root… \(s.itemsVisited.formatted()) items, \(ByteFormat.string(s.bytesSeen))"
                }
                source = .helper
            } else {
                dataTree = try await localScan(root: AppModel.dataRoot, label: "Data volume (limited)")
                source = .user
            }
            scanMessage = "Sorting into categories…"
            let rules = RuleSet.bundled(homeRelative: AppModel.homeRelative)
            let idx = await Task.detached(priority: .userInitiated) { CategoryIndex(tree: dataTree, rules: rules) }.value
            data = ScannedTree(tree: dataTree, source: source, date: Date())
            index = idx

            if helper.isReady {
                let pre = try await helper.scan(root: "/System/Volumes/Preboot") { [weak self] s in
                    self?.scanMessage = "Scanning Preboot… \(s.itemsVisited.formatted()) items"
                }
                preboot = ScannedTree(tree: pre, source: .helper, date: Date())
            }
        } catch is CancellationError {
            scanError = "Scan cancelled."
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func localScan(root: String, label: String) async throws -> FlatTree {
        let scanner = BulkScanner(rootPath: root)
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                let p = scanner.progress
                self?.scanMessage = "Scanning \(label)… \(p.itemsVisited.formatted()) items, \(ByteFormat.string(p.bytesSeen))"
            }
        }
        defer { poll.cancel() }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try scanner.scan() }.value
        } onCancel: {
            scanner.cancel()
        }
    }

    // MARK: - Derived numbers

    /// Volume consumed minus what the scan found. Negative when clones are counted twice.
    var dataUnexplained: Int64? {
        guard let v = volumes?.data, let t = data?.tree else { return nil }
        return Int64(v.consumed) - Int64(t.total[0])
    }

    /// The app's estimate of the macOS bar: system, Preboot and Recovery volumes plus /System on Data.
    var macOSEstimate: UInt64 {
        let v = volumes
        return (v?.system?.consumed ?? 0) + (v?.preboot?.consumed ?? 0) + (v?.recovery?.consumed ?? 0)
            + (index?.totals[.macOS] ?? 0)
    }

    /// System Data: Data-volume bytes the rules leave in System Data, plus swap, plus any
    /// positive unexplained remainder.
    var systemDataEstimate: UInt64 {
        let base = index?.totals[.systemData] ?? 0
        let vm = volumes?.vm?.consumed ?? 0
        let extra = max(dataUnexplained ?? 0, 0)
        return base + vm + UInt64(extra)
    }

    func total(for category: StorageCategory) -> UInt64 {
        switch category {
        case .macOS: return macOSEstimate
        case .systemData: return systemDataEstimate
        default: return index?.totals[category] ?? 0
        }
    }

    /// Removes a node's bytes from the in-memory model after it was moved to the Trash,
    /// by rescanning lazily. Simplest correct approach: mark data stale.
    var dataIsStale = false
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    static func string(signed bytes: Int64) -> String {
        bytes < 0 ? "−" + string(UInt64(-bytes)) : string(UInt64(bytes))
    }
}
