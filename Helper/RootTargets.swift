import Darwin
import Foundation

/// Cleanup targets that need root. Paths and commands are fixed here; the app only
/// ever sends target IDs.
enum RootTargets {
    static let libraryCachesID = "root.library-caches"
    static let unifiedLogsID = "root.unified-logs"
    static let snapshotPrefix = "root.tm-snapshot."

    static func list() -> [CleanupTarget] {
        var targets: [CleanupTarget] = []

        let caches = SafeDeleter.measureContents(of: "/Library/Caches")
        targets.append(CleanupTarget(
            id: libraryCachesID, group: "System caches",
            title: "System-wide caches (/Library/Caches)",
            detail: "Caches shared by all users. Apps and macOS rebuild them as needed.",
            executor: .root, defaultSelected: true, irreversible: true,
            estimatedBytes: caches.bytes, preview: caches.preview, command: nil))

        let logBytes = SafeDeleter.measureContents(of: "/private/var/db/diagnostics").bytes
            &+ SafeDeleter.measureContents(of: "/private/var/db/uuidtext").bytes
        targets.append(CleanupTarget(
            id: unifiedLogsID, group: "System logs",
            title: "Unified log history",
            detail: "Erases all macOS diagnostic log history, including what Apple Support and crash diagnosis rely on. The space comes back slowly as new logs are written.",
            executor: .root, defaultSelected: false, irreversible: true,
            estimatedBytes: logBytes, preview: ["/private/var/db/diagnostics", "/private/var/db/uuidtext"],
            command: "/usr/bin/log erase --all"))

        for date in localSnapshotDates() {
            targets.append(CleanupTarget(
                id: snapshotPrefix + date, group: "Time Machine local snapshots",
                title: "Local snapshot \(date)",
                detail: "A Time Machine snapshot kept on this disk. macOS deletes these on its own when space runs low or after 24 hours. Its size cannot be measured until it is gone.",
                executor: .root, defaultSelected: false, irreversible: true,
                estimatedBytes: nil, preview: [],
                command: "/usr/bin/tmutil deletelocalsnapshots \(date)"))
        }
        return targets
    }

    static func run(id: String) -> CleanupTargetResult {
        var result = CleanupTargetResult(targetID: id, freedBytes: 0, removed: 0, failed: 0, failures: [], output: nil)
        switch id {
        case libraryCachesID:
            let r = SafeDeleter.removeContents(of: "/Library/Caches")
            result.removed = r.removed
            result.freedBytes = r.freedBytes
            result.failed = r.failures.count
            result.failures = r.failures.prefix(50).map { CleanupItemResult(path: $0.path, ok: false, message: $0.reason) }
        case unifiedLogsID:
            let out = Command.run("/usr/bin/log", ["erase", "--all"], timeout: 120)
            result.output = out.output
            if out.status != 0 { result.failed = 1 } else { result.removed = 1 }
        case let s where s.hasPrefix(snapshotPrefix):
            let date = String(s.dropFirst(snapshotPrefix.count))
            guard isSnapshotDate(date) else { result.failed = 1; result.output = "Invalid snapshot date."; break }
            let out = Command.run("/usr/bin/tmutil", ["deletelocalsnapshots", date], timeout: 300)
            result.output = out.output
            if out.status != 0 { result.failed = 1 } else { result.removed = 1 }
        default:
            result.failed = 1
            result.output = "Unknown target."
        }
        return result
    }

    static func localSnapshotDates() -> [String] {
        let out = Command.run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], timeout: 30)
        guard out.status == 0 else { return [] }
        return out.output.split(separator: "\n").map(String.init).filter(isSnapshotDate)
    }

    /// `YYYY-MM-DD-HHMMSS`, the only form tmutil accepts.
    static func isSnapshotDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil
    }
}
