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
    private var chunks: [Data] = []
    private var invalidated = false

    init(uid: uid_t, pid: pid_t) {
        self.uid = uid
        self.pid = pid
    }

    func invalidate() {
        queue.sync {
            invalidated = true
            scanner?.cancel()
            chunks = []
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
            chunks = []
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
            let tree = try scanner.scan()
            let cancelled = scanner.progress.cancelled
            let data = cancelled ? Data() : tree.encoded()
            var parts: [Data] = []
            var offset = 0
            while offset < data.count {
                let end = min(offset + HelperConstants.chunkSize, data.count)
                parts.append(data.subdata(in: offset..<end))
                offset = end
            }
            queue.sync {
                guard !invalidated else { return }
                chunks = parts
                let p = scanner.progress
                status.itemsVisited = p.itemsVisited
                status.bytesSeen = p.bytesSeen
                status.state = cancelled ? .cancelled : .finished
                status.chunkCount = parts.count
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
            guard status.state == .finished, index >= 0, index < chunks.count else { return (nil, chunks.count) }
            let chunk = chunks[index]
            let total = chunks.count
            if index == total - 1 {
                chunks = []
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
            chunks = []
        }
        reply()
    }

    // MARK: Cleanup

    func rootCleanupTargets(reply: @escaping (Data) -> Void) {
        let targets = RootTargets.list()
        reply((try? JSONEncoder().encode(targets)) ?? Data())
    }

    func runRootCleanup(request: Data, authorization: Data, reply: @escaping (Data) -> Void) {
        func fail(_ message: String) {
            let report = CleanupReport(results: [], error: message)
            reply((try? JSONEncoder().encode(report)) ?? Data())
        }
        guard request.count <= HelperConstants.maxRequestBytes,
              let req = try? JSONDecoder().decode(CleanupRequest.self, from: request),
              !req.targetIDs.isEmpty, req.targetIDs.count <= 64 else {
            return fail("Bad request.")
        }
        guard AuthorizationCheck.verify(externalForm: authorization, right: HelperConstants.cleanupRight) else {
            helperLog.error("pid \(self.pid) cleanup refused: authorization failed")
            return fail("Administrator authorization was not granted.")
        }
        let known = Set(RootTargets.list().map(\.id))
        if let unknown = req.targetIDs.first(where: { !known.contains($0) }) {
            return fail("Unknown cleanup target: \(unknown)")
        }
        guard HelperLocks.claimCleanup() else { return fail("A cleanup is already running.") }
        IdleMonitor.shared.beginWork()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                HelperLocks.releaseCleanup()
                IdleMonitor.shared.endWork()
            }
            helperLog.notice("pid \(self.pid) uid \(self.uid) running cleanup: \(req.targetIDs.joined(separator: ","), privacy: .public)")
            let results = req.targetIDs.map { RootTargets.run(id: $0) }
            let report = CleanupReport(results: results, error: nil)
            reply((try? JSONEncoder().encode(report)) ?? Data())
        }
    }

    func exitForUpgrade(reply: @escaping () -> Void) {
        reply()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
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
                let status = AuthorizationCopyRights(authRef, &rights, nil, [.extendRights], nil)
                return status == errAuthorizationSuccess
            }
        }
    }
}
