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

    private static let O_NOFOLLOW_ANY: Int32 = 0x2000_0000
    private static let maxDepth = 256

    /// Removes the entries inside `directory`, never `directory` itself.
    ///
    /// - Parameters:
    ///   - keepTopLevel: return true for a top-level name to leave it alone.
    ///   - onlyTopLevel: when non-nil, only these top-level names are removed.
    ///   - requiredOwner: when set, any entry owned by another user is left in place.
    static func removeContents(of directory: String,
                               onlyTopLevel: Set<String>? = nil,
                               keepTopLevel: (String) -> Bool = { _ in false },
                               requiredOwner: uid_t? = nil) -> Result {
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
        for name in names {
            if let only = onlyTopLevel, !only.contains(name) { continue }
            if keepTopLevel(name) { continue }
            removeEntry(parentFD: dfd, name: name, device: st.st_dev, owner: requiredOwner,
                        displayPath: directory + "/" + name, depth: 0, result: &result)
        }
        return result
    }

    /// Bytes `removeContents` would free, measured the same way (allocated blocks of
    /// files with a single link), without deleting anything.
    static func measureContents(of directory: String,
                                onlyTopLevel: Set<String>? = nil,
                                keepTopLevel: (String) -> Bool = { _ in false }) -> (bytes: UInt64, preview: [String]) {
        let dfd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard dfd >= 0 else { return (0, []) }
        defer { close(dfd) }
        var st = stat()
        guard fstat(dfd, &st) == 0, let names = listNames(dfd) else { return (0, []) }
        var total: UInt64 = 0
        var preview: [String] = []
        for name in names.sorted() {
            if let only = onlyTopLevel, !only.contains(name) { continue }
            if keepTopLevel(name) { continue }
            total &+= measure(parentFD: dfd, name: name, device: st.st_dev, depth: 0)
            if preview.count < 40 { preview.append(directory + "/" + name) }
        }
        return (total, preview)
    }

    // MARK: - Internals

    private static func removeEntry(parentFD: Int32, name: String, device: dev_t, owner: uid_t?,
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
                    removeEntry(parentFD: cfd, name: child, device: device, owner: owner,
                                displayPath: displayPath + "/" + child, depth: depth + 1, result: &result)
                }
            }
            close(cfd)
            if unlinkat(parentFD, name, AT_REMOVEDIR) == 0 {
                result.removed += 1
            } else if errno != ENOTEMPTY {
                result.failures.append(Failure(path: displayPath, reason: String(cString: strerror(errno))))
            }
        } else {
            let bytes: UInt64 = st.st_nlink <= 1 ? UInt64(max(st.st_blocks, 0)) * 512 : 0
            if unlinkat(parentFD, name, 0) == 0 {
                result.removed += 1
                result.freedBytes &+= bytes
            } else {
                result.failures.append(Failure(path: displayPath, reason: String(cString: strerror(errno))))
            }
        }
    }

    private static func measure(parentFD: Int32, name: String, device: dev_t, depth: Int) -> UInt64 {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_dev == device else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return st.st_nlink <= 1 ? UInt64(max(st.st_blocks, 0)) * 512 : 0
        }
        guard depth < maxDepth else { return 0 }
        let cfd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cfd >= 0 else { return 0 }
        defer { close(cfd) }
        var total: UInt64 = 0
        for child in listNames(cfd) ?? [] {
            total &+= measure(parentFD: cfd, name: child, device: device, depth: depth + 1)
        }
        return total
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
