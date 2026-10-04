import Foundation

/// Who performs a cleanup target.
enum CleanupExecutor: String, Codable {
    /// The app, running as the logged-in user.
    case user
    /// The root helper.
    case root
}

/// One thing the Cleanup panel can remove.
struct CleanupTarget: Codable, Identifiable, Hashable {
    var id: String
    var group: String
    var title: String
    var detail: String
    var executor: CleanupExecutor
    /// Selected when the panel first loads.
    var defaultSelected: Bool
    /// True when the removal skips the Trash and cannot be undone.
    var irreversible: Bool
    /// Bytes this target currently holds, or nil when unknown until it runs.
    var estimatedBytes: UInt64?
    /// Up to a few dozen example paths shown in the preview.
    var preview: [String]
    /// The command line this target runs, if any, shown to the user before running.
    var command: String?
    /// True when the target can be limited to files not modified in N days.
    var supportsAge: Bool = false
}

/// Age choices offered for targets that support them. 0 means any age.
enum CleanupAge {
    static let choices = [0, 30, 60, 90]
    static func cutoff(days: Int) -> Date? {
        days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
    }
}

struct CleanupRequest: Codable {
    var targetIDs: [String]
    /// Per-target age filter in days; missing or 0 means any age.
    var olderThanDays: [String: Int]?
}

struct CleanupItemResult: Codable, Hashable {
    var path: String
    var ok: Bool
    var message: String?
}

struct CleanupTargetResult: Codable, Hashable {
    var targetID: String
    var freedBytes: UInt64
    var removed: Int
    var failed: Int
    var failures: [CleanupItemResult]
    var output: String?
}

struct CleanupReport: Codable {
    var results: [CleanupTargetResult]
    var error: String?
}
