import Darwin
import Foundation
import Security

/// Process-wide locks: one scan and one cleanup at a time across all connections.
enum HelperLocks {
    private static let lock = NSLock()
    private static var scanOwner: ObjectIdentifier?
    private static var cleanupRunning = false

    static func claimScan(_ owner: AnyObject) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if scanOwner != nil { return false }
        scanOwner = ObjectIdentifier(owner); return true
    }

    static func releaseScan(_ owner: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        if scanOwner == ObjectIdentifier(owner) { scanOwner = nil }
    }

    static func claimCleanup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cleanupRunning { return false }
        cleanupRunning = true; return true
    }

    static func releaseCleanup() {
        lock.lock(); defer { lock.unlock() }
        cleanupRunning = false
    }
}

/// State for one accepted connection. Scan results never leave the connection that made them.
final class HelperSession: NSObject, HelperProtocol {
    private let uid: uid_t
    private let pid: pid_t
    private let queue = DispatchQueue(label: "session")
    private var scanner: BulkScanner?
    private var status = ScanStatus(state: .idle, root: nil, itemsVisited: 0, bytesSeen: 0, error: nil, chunkCount: 0)
    /// Encoded tree, sliced into chunks on demand so only one copy is held.
    private var encodedTree = Data()
    private var chunkCount: Int { (encodedTree.count + HelperConstants.chunkSize - 1) / HelperConstants.chunkSize }
    private var invalidated = false

    init(uid: uid_t, pid: pid_t) {
        self.uid = uid
        self.pid = pid
    }

    func invalidate() {
        queue.sync {
            invalidated = true
            scanner?.cancel()
            encodedTree = Data()
        }
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }

    // MARK: Scanning

    func startScan(root: String, reply: @escaping (String?) -> Void) {
        guard HelperConstants.allowedScanRoots.contains(root) else {
            helperLog.error("pid \(self.pid) asked to scan a disallowed root")
            reply("That folder is not on the helper's scan list.")
            return
        }
        let error: String? = queue.sync {
            if status.state == .running { return "A scan is already running." }
            guard HelperLocks.claimScan(self) else { return "Another window is scanning. Try again when it finishes." }
            let scanner = BulkScanner(rootPath: root)
            self.scanner = scanner
            encodedTree = Data()
            status = ScanStatus(state: .running, root: root, itemsVisited: 0, bytesSeen: 0, error: nil, chunkCount: 0)
            IdleMonitor.shared.beginWork()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.runScan(scanner)
            }
            return nil
        }
        reply(error)
    }

    private func runScan(_ scanner: BulkScanner) {
        defer {
            HelperLocks.releaseScan(self)
            IdleMonitor.shared.endWork()
        }
        do {
            // The tree goes out of scope once encoded, so only the encoding stays in memory.
            let data: Data = try autoreleasepool {
                let tree = try scanner.scan()
                return scanner.progress.cancelled ? Data() : tree.encoded()
            }
            let cancelled = scanner.progress.cancelled
            queue.sync {
                guard !invalidated else { return }
                encodedTree = data
                let p = scanner.progress
                status.itemsVisited = p.itemsVisited
                status.bytesSeen = p.bytesSeen
                status.state = cancelled ? .cancelled : .finished
                status.chunkCount = chunkCount
                self.scanner = nil
            }
        } catch {
            queue.sync {
                status.state = .failed
                status.error = error.localizedDescription
                self.scanner = nil
            }
        }
    }

    func scanStatus(reply: @escaping (Data) -> Void) {
        let snapshot: ScanStatus = queue.sync {
            var s = status
            if let scanner, s.state == .running {
                let p = scanner.progress
                s.itemsVisited = p.itemsVisited
                s.bytesSeen = p.bytesSeen
            }
            return s
        }
        reply((try? JSONEncoder().encode(snapshot)) ?? Data())
    }

    func fetchTreeChunk(index: Int, reply: @escaping (Data?, Int) -> Void) {
        let result: (Data?, Int) = queue.sync {
            let total = chunkCount
            guard status.state == .finished, index >= 0, index < total else { return (nil, total) }
            let start = index * HelperConstants.chunkSize
            let end = min(start + HelperConstants.chunkSize, encodedTree.count)
            let chunk = encodedTree.subdata(in: start..<end)
            if index == total - 1 {
                encodedTree = Data()
                status = ScanStatus(state: .idle, root: nil, itemsVisited: status.itemsVisited,
                                    bytesSeen: status.bytesSeen, error: nil, chunkCount: 0)
            }
            return (chunk, total)
        }
        reply(result.0, result.1)
    }

    func cancelScan(reply: @escaping () -> Void) {
        queue.sync {
            scanner?.cancel()
            encodedTree = Data()
        }
        reply()
    }

    // MARK: Cleanup

    func rootCleanupTargets(reply: @escaping (Data) -> Void) {
        let targets = RootTargets.list()
        reply((try? JSONEncoder().encode(targets)) ?? Data())
    }

    func rootTargetItems(targetID: String, olderThanDays: Int, reply: @escaping (Data) -> Void) {
        guard RootTargets.isValidID(targetID), CleanupAge.choices.contains(olderThanDays) else {
            reply(Data("[]".utf8)); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = RootTargets.items(id: targetID, olderThanDays: olderThanDays)
            reply((try? JSONEncoder().encode(items)) ?? Data("[]".utf8))
        }
    }

    func runRootCleanup(request: Data, authorization: Data, reply: @escaping (Data) -> Void) {
        func fail(_ message: String) {
            let report = CleanupReport(results: [], error: message)
            reply((try? JSONEncoder().encode(report)) ?? Data())
        }
        guard request.count <= HelperConstants.maxRequestBytes,
              let decoded = try? JSONDecoder().decode(CleanupRequest.self, from: request),
              !decoded.targetIDs.isEmpty, decoded.targetIDs.count <= 64 else {
            return fail("Bad request.")
        }
        var seen = Set<String>()
        let ids = decoded.targetIDs.filter { seen.insert($0).inserted }
        // Only the offered age choices are accepted; anything else means "any age" is not assumed.
        let ages = decoded.olderThanDays ?? [:]
        guard ages.values.allSatisfy({ CleanupAge.choices.contains($0) }) else { return fail("Bad age filter.") }
        guard AuthorizationCheck.verify(externalForm: authorization, right: HelperConstants.cleanupRight) else {
            helperLog.error("pid \(self.pid) cleanup refused: authorization failed")
            return fail("Administrator authorization was not granted.")
        }
        if let unknown = ids.first(where: { !RootTargets.isValidID($0) }) {
            return fail("Unknown cleanup target: \(unknown)")
        }
        guard HelperLocks.claimCleanup() else { return fail("A cleanup is already running.") }
        IdleMonitor.shared.beginWork()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                HelperLocks.releaseCleanup()
                IdleMonitor.shared.endWork()
            }
            helperLog.notice("pid \(self.pid) uid \(self.uid) running cleanup: \(ids.joined(separator: ","), privacy: .public)")
            let results = ids.map { RootTargets.run(id: $0, olderThanDays: ages[$0] ?? 0) }
            let report = CleanupReport(results: results, error: nil)
            reply((try? JSONEncoder().encode(report)) ?? Data())
        }
    }

    /// Exits so launchd starts the binary from the current app bundle next time. Refused
    /// while any connection has a scan or cleanup in flight.
    func exitForUpgrade(reply: @escaping () -> Void) {
        reply()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            guard !IdleMonitor.shared.isBusy else {
                helperLog.info("upgrade exit postponed: work in flight")
                return
            }
            helperLog.info("exiting for upgrade")
            exit(0)
        }
    }
}

enum AuthorizationCheck {
    /// Verifies, without user interaction, that the external form carries `right`.
    static func verify(externalForm data: Data, right: String) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var ext = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &ext) { dst in data.copyBytes(to: dst) }
        var authRef: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&ext, &authRef) == errAuthorizationSuccess, let authRef else {
            return false
        }
        defer { AuthorizationFree(authRef, []) }
        return right.withCString { name -> Bool in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr -> Bool in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                // No .extendRights: succeed only if the app already obtained this right in
                // that authorization, so being root here never satisfies the check by itself.
                let status = AuthorizationCopyRights(authRef, &rights, nil, [], nil)
                return status == errAuthorizationSuccess
            }
        }
    }
}

enum AuthorizationRight {
    /// Registers the cleanup right in the authorization database if it is missing: admin
    /// password every time (timeout 0), never shared, and root alone does not satisfy it.
    static func ensureRegistered() {
        let name = HelperConstants.cleanupRight
        if AuthorizationRightGet(name, nil) == errAuthorizationSuccess { return }
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let authRef else { return }
        defer { AuthorizationFree(authRef, []) }
        let rule: [String: Any] = [
            "class": "user",
            "group": "admin",
            "shared": false,
            "allow-root": false,
            "timeout": 0,
            "authenticate-user": true,
            "session-owner": false,
            "version": 1,
            "comment": "Used by SpacePig before its helper removes system-wide files.",
        ]
        let status = AuthorizationRightSet(authRef, name, rule as CFDictionary,
                                           "SpacePig wants to remove system caches or logs." as CFString, nil, nil)
        if status != errAuthorizationSuccess {
            helperLog.error("could not register authorization right: \(status)")
        }
    }
}
