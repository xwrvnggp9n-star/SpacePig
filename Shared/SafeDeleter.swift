import Darwin
import Foundation

/// Deletes directory contents without following symlinks and without path-based races.
///
/// Every operation is relative to a directory file descriptor that is already open:
/// the starting directory is opened with `O_NOFOLLOW_ANY` (no symlink anywhere in its
/// path), each subdirectory with `openat(O_NOFOLLOW)` and then checked against the
/// device and inode seen a moment earlier, and entries are removed with `unlinkat`.
/// Replacing a directory with a symlink, or swapping it for another directory, while
/// the walk runs makes that entry fail instead of redirecting the delete. The walk
/// never crosses into another device (mount points, disk images).
///
/// With `olderThan`, only files last modified before that date are removed; folders
/// are removed only once they end up empty.
enum SafeDeleter {
    struct Failure: Hashable {
        var path: String
        var reason: String
    }

    struct Result {
        var removed = 0
        var freedBytes: UInt64 = 0
        var failures: [Failure] = []
    }

    /// Which top-level entries of a directory a target covers.
    struct Scope {
        var onlyTopLevel: Set<String>? = nil
        var keepTopLevel: (String) -> Bool = { _ in false }
        /// Only files modified before this date count. nil means every file.
        var olderThan: Date? = nil

        func includes(_ name: String) -> Bool {
            if let only = onlyTopLevel, !only.contains(name) { return false }
            return !keepTopLevel(name)
        }
    }

    private static let O_NOFOLLOW_ANY: Int32 = 0x2000_0000
    private static let maxDepth = 256

    // MARK: - Removing

    /// Removes the covered entries inside `directory`, never `directory` itself.
    /// - Parameter requiredOwner: when set, any entry owned by another user is left in place.
    static func removeContents(of directory: String, scope: Scope, requiredOwner: uid_t? = nil) -> Result {
        var result = Result()
        let dfd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard dfd >= 0 else {
            if errno != ENOENT {
                result.failures.append(Failure(path: directory, reason: String(cString: strerror(errno))))
            }
            return result
        }
        defer { close(dfd) }
        var st = stat()
        guard fstat(dfd, &st) == 0 else {
            result.failures.append(Failure(path: directory, reason: "fstat failed"))
            return result
        }
        guard let names = listNames(dfd) else {
            result.failures.append(Failure(path: directory, reason: "cannot list"))
            return result
        }
        let cutoff = scope.olderThan.map { time_t($0.timeIntervalSince1970) }
        for name in names where scope.includes(name) {
            removeEntry(parentFD: dfd, name: name, device: st.st_dev, owner: requiredOwner, cutoff: cutoff,
                        displayPath: directory + "/" + name, depth: 0, result: &result)
        }
        return result
    }

    /// Kept for callers that predate `Scope`.
    static func removeContents(of directory: String,
                               onlyTopLevel: Set<String>? = nil,
                               keepTopLevel: @escaping (String) -> Bool = { _ in false },
                               requiredOwner: uid_t? = nil) -> Result {
        removeContents(of: directory, scope: Scope(onlyTopLevel: onlyTopLevel, keepTopLevel: keepTopLevel),
                       requiredOwner: requiredOwner)
    }

    // MARK: - Measuring

    /// One top-level entry a cleanup would touch.
    struct Item: Codable, Hashable {
        var path: String
        /// Bytes that would be freed (only files that match the age filter).
        var bytes: UInt64
        /// Newest modification date among the files that would be removed.
        var newestModified: Date?
        var isDirectory: Bool
        var files: Int
    }

    /// Every covered top-level entry with the bytes removal would free, largest first.
    /// Entries with nothing to remove (everything too new) are left out.
    static func items(of directory: String, scope: Scope = Scope()) -> [Item] {
        let dfd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard dfd >= 0 else { return [] }
        defer { close(dfd) }
        var st = stat()
        guard fstat(dfd, &st) == 0, let names = listNames(dfd) else { return [] }
        let cutoff = scope.olderThan.map { time_t($0.timeIntervalSince1970) }
        var out: [Item] = []
        for name in names where scope.includes(name) {
            var acc = Tally()
            var est = stat()
            guard fstatat(dfd, name, &est, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            measure(parentFD: dfd, name: name, device: st.st_dev, cutoff: cutoff, depth: 0, into: &acc)
            guard acc.files > 0 else { continue }
            out.append(Item(path: directory + "/" + name, bytes: acc.bytes,
                            newestModified: acc.newest > 0 ? Date(timeIntervalSince1970: TimeInterval(acc.newest)) : nil,
                            isDirectory: (est.st_mode & S_IFMT) == S_IFDIR, files: acc.files))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Bytes `removeContents` would free with the same scope, plus a short preview.
    static func measureContents(of directory: String, scope: Scope) -> (bytes: UInt64, preview: [String]) {
        let list = items(of: directory, scope: scope)
        return (list.reduce(0) { $0 &+ $1.bytes }, list.prefix(40).map(\.path))
    }

    /// Kept for callers that predate `Scope`.
    static func measureContents(of directory: String,
                                onlyTopLevel: Set<String>? = nil,
                                keepTopLevel: @escaping (String) -> Bool = { _ in false }) -> (bytes: UInt64, preview: [String]) {
        measureContents(of: directory, scope: Scope(onlyTopLevel: onlyTopLevel, keepTopLevel: keepTopLevel))
    }

    // MARK: - Internals

    private struct Tally {
        var bytes: UInt64 = 0
        var files = 0
        var newest: time_t = 0
    }

    private static func isOldEnough(_ st: stat, cutoff: time_t?) -> Bool {
        guard let cutoff else { return true }
        return st.st_mtimespec.tv_sec < cutoff
    }

    private static func removeEntry(parentFD: Int32, name: String, device: dev_t, owner: uid_t?, cutoff: time_t?,
                                    displayPath: String, depth: Int, result: inout Result) {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            result.failures.append(Failure(path: displayPath, reason: String(cString: strerror(errno))))
            return
        }
        guard st.st_dev == device else {
            result.failures.append(Failure(path: displayPath, reason: "on another device; skipped"))
            return
        }
        if let owner, st.st_uid != owner {
            result.failures.append(Failure(path: displayPath, reason: "owned by another user; skipped"))
            return
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            guard depth < maxDepth else {
                result.failures.append(Failure(path: displayPath, reason: "too deep; skipped"))
                return
            }
            let cfd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard cfd >= 0 else {
                result.failures.append(Failure(path: displayPath, reason: String(cString: strerror(errno))))
                return
            }
            var cst = stat()
            guard fstat(cfd, &cst) == 0, cst.st_ino == st.st_ino, cst.st_dev == device else {
                close(cfd)
                result.failures.append(Failure(path: displayPath, reason: "changed during cleanup; skipped"))
                return
            }
            if let names = listNames(cfd) {
                for child in names {
                    removeEntry(parentFD: cfd, name: child, device: device, owner: owner, cutoff: cutoff,
                                displayPath: displayPath + "/" + child, depth: depth + 1, result: &result)
                }
            }
            close(cfd)
            // A folder that still holds newer files stays; that is expected with an age filter.
            if unlinkat(parentFD, name, AT_REMOVEDIR) == 0 {
                result.removed += 1
            } else if errno != ENOTEMPTY {
                result.failures.append(Failure(path: displayPath, reason: String(cString: strerror(errno))))
            }
        } else {
            guard isOldEnough(st, cutoff: cutoff) else { return }
            let bytes: UInt64 = st.st_nlink <= 1 ? UInt64(max(st.st_blocks, 0)) * 512 : 0
            if unlinkat(parentFD, name, 0) == 0 {
                result.removed += 1
                result.freedBytes &+= bytes
            } else {
                result.failures.append(Failure(path: displayPath, reason: String(cString: strerror(errno))))
            }
        }
    }

    private static func measure(parentFD: Int32, name: String, device: dev_t, cutoff: time_t?, depth: Int,
                                into acc: inout Tally) {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_dev == device else { return }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            guard isOldEnough(st, cutoff: cutoff) else { return }
            acc.files += 1
            acc.bytes &+= st.st_nlink <= 1 ? UInt64(max(st.st_blocks, 0)) * 512 : 0
            acc.newest = max(acc.newest, st.st_mtimespec.tv_sec)
            return
        }
        guard depth < maxDepth else { return }
        let cfd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cfd >= 0 else { return }
        defer { close(cfd) }
        for child in listNames(cfd) ?? [] {
            measure(parentFD: cfd, name: child, device: device, cutoff: cutoff, depth: depth + 1, into: &acc)
        }
    }

    /// Lists entry names of an open directory without disturbing the caller's descriptor.
    static func listNames(_ fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let dir = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }
}
