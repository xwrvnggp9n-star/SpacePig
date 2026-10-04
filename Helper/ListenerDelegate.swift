import Darwin
import Foundation

enum HelperInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Accepts a connection only from the release-signed SystemDataLens app run by an admin.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        let uid = connection.effectiveUserIdentifier

        guard UserAccounts.isAdmin(uid: uid) else {
            helperLog.error("rejected pid \(pid) uid \(uid): not an admin")
            return false
        }

        // Checked by the system against the caller's audit token for every message.
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)

        let session = HelperSession(uid: uid, pid: pid)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = {
            session.invalidate()
            IdleMonitor.shared.connectionClosed()
        }
        connection.interruptionHandler = {
            session.invalidate()
        }
        IdleMonitor.shared.connectionOpened()
        connection.resume()
        helperLog.info("accepted pid \(pid) uid \(uid)")
        return true
    }
}

enum UserAccounts {
    /// True when `uid` belongs to group `admin` (gid 80), checked through Directory
    /// Services so nested and network group memberships count.
    static func isAdmin(uid: uid_t) -> Bool {
        var user = [UInt8](repeating: 0, count: 16)
        var group = [UInt8](repeating: 0, count: 16)
        guard mbr_uid_to_uuid(uid, &user) == 0, mbr_gid_to_uuid(80, &group) == 0 else { return false }
        var isMember: Int32 = 0
        guard mbr_check_membership(&user, &group, &isMember) == 0 else { return false }
        return isMember != 0
    }
}

// <membership.h> is not exposed to Swift; these live in libSystem.
@_silgen_name("mbr_uid_to_uuid")
private func mbr_uid_to_uuid(_ uid: uid_t, _ uu: UnsafeMutablePointer<UInt8>) -> Int32
@_silgen_name("mbr_gid_to_uuid")
private func mbr_gid_to_uuid(_ gid: gid_t, _ uu: UnsafeMutablePointer<UInt8>) -> Int32
@_silgen_name("mbr_check_membership")
private func mbr_check_membership(_ user: UnsafeMutablePointer<UInt8>, _ group: UnsafeMutablePointer<UInt8>,
                                  _ isMember: UnsafeMutablePointer<Int32>) -> Int32

/// Exits the helper after two minutes with no connections and no work in flight.
final class IdleMonitor {
    static let shared = IdleMonitor()
    private let queue = DispatchQueue(label: "idle")
    private var connections = 0
    private var busy = 0
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func connectionOpened() { queue.sync { connections += 1; lastActivity = Date() } }
    func connectionClosed() { queue.sync { connections -= 1; lastActivity = Date() } }
    func beginWork() { queue.sync { busy += 1; lastActivity = Date() } }
    func endWork() {
        queue.sync { busy -= 1; lastActivity = Date() }
        queue.async { [weak self] in self?.check() }
    }
    var isBusy: Bool { queue.sync { busy > 0 } }
    /// Set when the helper's executable was replaced; exit as soon as no work is in flight.
    private var exitWhenIdle = false
    func requestExitWhenIdle() {
        queue.sync { exitWhenIdle = true }
        queue.async { [weak self] in self?.check() }
    }

    private func check() {
        if exitWhenIdle && busy <= 0 {
            helperLog.info("executable replaced; exiting so launchd starts the new one")
            exit(0)
        }
        if connections <= 0 && busy <= 0 && Date().timeIntervalSince(lastActivity) > 120 {
            helperLog.info("idle; exiting")
            exit(0)
        }
    }
}

/// Exits the helper once its executable is deleted or replaced (an app update). Otherwise
/// the old process keeps running with a signature the new app rightly refuses.
enum BinaryWatcher {
    private static var source: DispatchSourceFileSystemObject?

    static func start() {
        guard let path = Bundle.main.executablePath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .write, .revoke],
                                                          queue: .global())
        s.setEventHandler { IdleMonitor.shared.requestExitWhenIdle() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
