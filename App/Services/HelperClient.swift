import AppKit
import Foundation
import Observation
import Security
import ServiceManagement

enum HelperError: LocalizedError {
    case notReady, connection(String), helper(String), badReply
    var errorDescription: String? {
        switch self {
        case .notReady: return "The helper is not installed and approved."
        case .connection(let s): return "Could not talk to the helper: \(s)"
        case .helper(let s): return s
        case .badReply: return "The helper sent a reply this app could not read."
        }
    }
}

/// Registers, approves, upgrades and talks to the root helper.
@MainActor
@Observable
final class HelperClient {
    enum State: Equatable {
        case checking
        /// The app runs from a disk image or a translocated copy; registering would break.
        case wrongLocation
        case notInstalled
        case needsApproval
        case ready(version: String)
        case failed(String)
    }

    private(set) var state: State = .checking
    private let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var retriedAfterFailure = false

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    static var runningFromSafeLocation: Bool {
        let path = Bundle.main.bundlePath
        return !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
    }

    func refresh() async {
        guard HelperClient.runningFromSafeLocation else { state = .wrongLocation; return }
        switch service.status {
        case .notRegistered, .notFound:
            state = .notInstalled
        case .requiresApproval:
            state = .needsApproval
        case .enabled:
            await connectAndCheckVersion()
        @unknown default:
            state = .failed("Unknown helper status.")
        }
    }

    func install() async {
        guard HelperClient.runningFromSafeLocation else { state = .wrongLocation; return }
        do {
            try service.register()
        } catch {
            // Approval pending is reported as an error but is the normal first-run path.
            if service.status != .requiresApproval {
                state = .failed(error.localizedDescription)
                return
            }
        }
        await refresh()
        if state == .needsApproval {
            SMAppService.openSystemSettingsLoginItems()
            // Watch for the user flipping the switch, for up to three minutes.
            for _ in 0..<90 where state == .needsApproval {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Full reinstall: unregister, wait, register again.
    func reinstall() async {
        dropConnection()
        try? await service.unregister()
        try? await Task.sleep(for: .seconds(1))
        await install()
    }

    private func connectAndCheckVersion() async {
        do {
            let version = try await call { proxy, done in proxy.helperVersion { done(.success($0)) } }
            if version == HelperClient.appVersion {
                state = .ready(version: version)
                return
            }
            // An older helper is still running. Ask it to exit; launchd starts the
            // binary inside the current app bundle on the next connection.
            _ = try? await call { proxy, done in proxy.exitForUpgrade { done(.success(())) } }
            dropConnection()
            try? await Task.sleep(for: .seconds(1))
            try? service.register()
            let again = try await call { proxy, done in proxy.helperVersion { done(.success($0)) } }
            state = again == HelperClient.appVersion
                ? .ready(version: again)
                : .failed("Helper version \(again) does not match the app (\(HelperClient.appVersion)). Use Reinstall Helper.")
        } catch {
            // Usually an old helper whose executable was replaced by an app update: this app
            // refuses its stale signature. Restart it through launchd once, then report.
            if !retriedAfterFailure {
                retriedAfterFailure = true
                await reinstall()
                return
            }
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - XPC

    private func proxyConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.setCodeSigningRequirement(HelperConstants.helperRequirement)
        c.invalidationHandler = { [weak self, weak c] in
            Task { @MainActor in if let self, self.connection === c { self.connection = nil } }
        }
        c.interruptionHandler = { [weak self, weak c] in
            Task { @MainActor in if let self, self.connection === c { self.connection = nil } }
        }
        c.resume()
        connection = c
        return c
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
    }

    /// Calls the helper and resumes exactly once, whether the reply or the error handler fires.
    private func call<T>(_ body: @escaping (HelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let c = proxyConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let finish: (Result<T, Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(HelperError.connection(error.localizedDescription)))
            }) as? HelperProtocol else {
                finish(.failure(HelperError.badReply))
                return
            }
            body(proxy, finish)
        }
    }

    // MARK: - Operations

    /// Scans one of the allowed roots in the helper and downloads the resulting tree.
    func scan(root: String, progress: @escaping @MainActor (ScanStatus) -> Void) async throws -> FlatTree {
        guard isReady else { throw HelperError.notReady }
        let startError: String? = try await call { proxy, done in
            proxy.startScan(root: root) { done(.success($0)) }
        }
        if let startError { throw HelperError.helper(startError) }
        var status: ScanStatus
        repeat {
            // try? so cancellation falls through to the check below and reaches the helper.
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled {
                _ = try? await call { proxy, done in proxy.cancelScan { done(.success(())) } }
                throw CancellationError()
            }
            let data: Data = try await call { proxy, done in proxy.scanStatus { done(.success($0)) } }
            guard let s = try? JSONDecoder().decode(ScanStatus.self, from: data) else { throw HelperError.badReply }
            status = s
            progress(s)
        } while status.state == .running

        switch status.state {
        case .failed: throw HelperError.helper(status.error ?? "Scan failed.")
        case .cancelled: throw CancellationError()
        default: break
        }
        var blob = Data()
        var index = 0
        var total = 1
        while index < total {
            let (chunk, count): (Data?, Int) = try await call { proxy, done in
                proxy.fetchTreeChunk(index: index) { done(.success(($0, $1))) }
            }
            guard let chunk else { throw HelperError.badReply }
            blob.append(chunk)
            total = count
            index += 1
        }
        let tree = try await Task.detached(priority: .userInitiated) { try FlatTree.decode(blob) }.value
        return tree
    }

    func rootTargets() async throws -> [CleanupTarget] {
        guard isReady else { return [] }
        let data: Data = try await call { proxy, done in proxy.rootCleanupTargets { done(.success($0)) } }
        guard let targets = try? JSONDecoder().decode([CleanupTarget].self, from: data) else { throw HelperError.badReply }
        return targets
    }

    /// Asks for an administrator password (or Touch ID), then runs root targets.
    /// Shows the administrator prompt. Call before deleting anything, so cancelling it
    /// leaves the whole cleanup undone.
    nonisolated func authorizeCleanup() async throws -> AdminAuthorization {
        try await Task.detached { try AdminAuthorization() }.value
    }

    func runRootCleanup(ids: [String], auth: AdminAuthorization) async throws -> CleanupReport {
        guard isReady else { throw HelperError.notReady }
        let request = try JSONEncoder().encode(CleanupRequest(targetIDs: ids))
        let form = auth.externalForm
        let data: Data = try await call { proxy, done in
            proxy.runRootCleanup(request: request, authorization: form) { done(.success($0)) }
        }
        withExtendedLifetime(auth) {}
        guard let report = try? JSONDecoder().decode(CleanupReport.self, from: data) else { throw HelperError.badReply }
        if let err = report.error { throw HelperError.helper(err) }
        return report
    }
}

/// Thread-safe one-shot flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Holds an AuthorizationRef with the admin right for as long as the helper needs it.
final class AdminAuthorization: @unchecked Sendable {
    private var ref: AuthorizationRef?
    let externalForm: Data

    struct Denied: LocalizedError { var errorDescription: String? { "Administrator authorization was cancelled." } }

    /// - Parameter withoutRights: self-test only; produces a valid authorization that holds no rights.
    init(withoutRights: Bool = false) throws {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { throw Denied() }
        if withoutRights {
            var ext = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(ref, &ext) == errAuthorizationSuccess else { throw Denied() }
            self.ref = ref
            self.externalForm = withUnsafeBytes(of: &ext) { Data($0) }
            return
        }
        let status: OSStatus = HelperConstants.cleanupRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            throw Denied()
        }
        var ext = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &ext) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            throw Denied()
        }
        self.ref = ref
        self.externalForm = withUnsafeBytes(of: &ext) { Data($0) }
    }

    deinit {
        if let ref { AuthorizationFree(ref, [.destroyRights]) }
    }
}

/// `open -a SystemDataLens --args --selftest-auth` checks that the helper refuses a
/// cleanup request carrying an authorization with no rights, writes the result to
/// ~/Library/Logs/SystemDataLens-selftest.log, and quits. The request names a snapshot
/// date that cannot exist, so nothing is deleted even if the check were to fail.
enum SelfTest {
    @MainActor
    static func runIfRequested(_ helper: HelperClient) async {
        guard CommandLine.arguments.contains("--selftest-auth") else { return }
        var lines: [String] = ["SystemDataLens self-test \(Date())", "helper state: \(helper.state)"]
        if helper.isReady {
            do {
                let empty = try AdminAuthorization(withoutRights: true)
                _ = try await helper.runRootCleanup(ids: ["root.tm-snapshot.2000-01-01-000000"], auth: empty)
                lines.append("FAIL: helper accepted an authorization without rights")
            } catch {
                let msg = error.localizedDescription
                lines.append((msg.contains("not granted") ? "PASS" : "UNEXPECTED") + ": \(msg)")
            }
        } else {
            lines.append("SKIP: helper not ready")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/SystemDataLens-selftest.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        NSApplication.shared.terminate(nil)
    }
}
