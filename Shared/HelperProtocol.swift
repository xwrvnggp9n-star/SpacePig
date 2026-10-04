import Foundation

/// Identifiers and code-signing requirements shared by the app and the root helper.
enum HelperConstants {
    static let machServiceName = "app.sklar.SpacePig.helper"
    static let launchdPlistName = "app.sklar.SpacePig.helper.plist"
    static let appIdentifier = "app.sklar.SpacePig"
    static let helperIdentifier = "app.sklar.SpacePig.helper"
    static let teamID = "5Y3S9Y6Z27"

    /// Developer ID Application leaf marker OID. Excludes Apple Development certificates.
    private static let developerIDLeaf = "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// What the helper demands of a connecting client.
    static let clientRequirement =
        "anchor apple generic and identifier \"\(appIdentifier)\" " +
        "and certificate leaf[subject.OU] = \"\(teamID)\" and \(developerIDLeaf) " +
        "and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"

    /// What the app demands of the helper it connects to.
    static let helperRequirement =
        "anchor apple generic and identifier \"\(helperIdentifier)\" " +
        "and certificate leaf[subject.OU] = \"\(teamID)\" and \(developerIDLeaf)"

    /// Authorization right the app must obtain (admin password or Touch ID) before root
    /// cleanup. The helper registers it with `allow-root` off and no credential sharing.
    static let cleanupRight = "app.sklar.SpacePig.cleanup"

    /// The only directories the helper will scan.
    static let allowedScanRoots = ["/System/Volumes/Data", "/System/Volumes/Preboot"]

    /// Size of each tree chunk sent over XPC.
    static let chunkSize = 8 * 1024 * 1024
    /// Upper bound on any request payload the helper will decode.
    static let maxRequestBytes = 64 * 1024
}

/// XPC interface exported by the root helper. All structured payloads are JSON `Data`.
@objc(SDLHelperProtocol)
protocol HelperProtocol {
    /// Returns "<short version> (<build>)" of the running helper.
    func helperVersion(reply: @escaping (String) -> Void)

    /// Starts a scan of one of `HelperConstants.allowedScanRoots`. Replies with an error string or nil.
    func startScan(root: String, reply: @escaping (String?) -> Void)

    /// JSON-encoded `ScanStatus`.
    func scanStatus(reply: @escaping (Data) -> Void)

    /// Returns chunk `index` of the encoded tree and the total chunk count. The tree is
    /// freed after the last chunk is fetched.
    func fetchTreeChunk(index: Int, reply: @escaping (Data?, Int) -> Void)

    func cancelScan(reply: @escaping () -> Void)

    /// JSON-encoded `[CleanupTarget]` for root-owned targets.
    func rootCleanupTargets(reply: @escaping (Data) -> Void)

    /// `request` is JSON `CleanupRequest`; `authorization` is an `AuthorizationExternalForm`.
    /// Replies with JSON `CleanupReport`.
    func runRootCleanup(request: Data, authorization: Data, reply: @escaping (Data) -> Void)

    /// Asks the helper to exit so launchd starts the new binary on the next connection.
    func exitForUpgrade(reply: @escaping () -> Void)
}

struct ScanStatus: Codable, Equatable {
    enum State: String, Codable { case idle, running, finished, failed, cancelled }
    var state: State
    var root: String?
    var itemsVisited: Int
    var bytesSeen: UInt64
    var error: String?
    var chunkCount: Int
}
