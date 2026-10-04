import Darwin
import Foundation
import os

/// Walks a directory tree with `getattrlistbulk(2)` and builds a `FlatTree`.
///
/// - Never follows symlinks and never leaves the starting device.
/// - Turns off materialization of dataless (cloud placeholder) files for the whole
///   process first, so scanning never triggers iCloud or File Provider downloads.
/// - Counts each hard-linked file once (by file ID; APFS link IDs differ per link).
/// - Folds files smaller than `aggregateBelow` into one node per directory.
final class BulkScanner {
    struct Progress: Equatable {
        var itemsVisited = 0
        var bytesSeen: UInt64 = 0
        var cancelled = false
    }

    let rootPath: String
    let aggregateBelow: UInt64
    /// Absolute directory paths to list but not descend (marked `.otherDevice`).
    let excludedPaths: Set<String>
    private let state = OSAllocatedUnfairLock(initialState: Progress())

    init(rootPath: String, aggregateBelow: UInt64 = 1 << 20, excludedPaths: Set<String>? = nil) {
        self.rootPath = rootPath
        self.aggregateBelow = aggregateBelow
        self.excludedPaths = excludedPaths ?? (rootPath == "/" ? BulkScanner.systemVolumeExclusions() : [])
    }

    /// Firmlinks make Data-volume folders appear inside the sealed system volume with the
    /// same device number, so a scan of "/" must skip them by path, along with the
    /// other mounted volumes under /System/Volumes.
    static func systemVolumeExclusions() -> Set<String> {
        var paths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home"]
        if let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let first = line.split(separator: "\t").first, first.hasPrefix("/") { paths.insert(String(first)) }
            }
        }
        return paths
    }

    var progress: Progress { state.withLock { $0 } }

    func cancel() { state.withLock { $0.cancelled = true } }

    private var isCancelled: Bool { state.withLock { $0.cancelled } }

    enum ScanError: Error, LocalizedError {
        case cannotOpenRoot(String, Int32)
        var errorDescription: String? {
            switch self {
            case let .cannotOpenRoot(p, e): return "Cannot open \(p): \(String(cString: strerror(e)))"
            }
        }
    }

    /// Process-wide: stop the kernel from downloading dataless files when they are touched.
    static func disableDatalessMaterialization() {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3, IOPOL_SCOPE_PROCESS = 0,
        // IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1
        _ = setiopolicy_np(3, 0, 1)
    }

    // MARK: getattrlistbulk constants (sys/attr.h)

    private enum A {
        static let bitmapCount: UInt16 = 5
        static let cmnName: UInt32 = 0x0000_0001
        static let cmnDevID: UInt32 = 0x0000_0002
        static let cmnObjType: UInt32 = 0x0000_0008
        static let cmnFlags: UInt32 = 0x0004_0000
        static let cmnFileID: UInt32 = 0x0200_0000
        static let cmnError: UInt32 = 0x2000_0000
        static let cmnReturned: UInt32 = 0x8000_0000
        static let dirMountStatus: UInt32 = 0x0000_0004
        static let fileLinkCount: UInt32 = 0x0000_0001
        static let fileAllocSize: UInt32 = 0x0000_0004
        static let extPrivateSize: UInt32 = 0x0000_0008
        static let extFlags: UInt32 = 0x0000_0200
        static let optCmnExtended: UInt64 = 0x0000_0020
        static let mntStatusMountPoint: UInt32 = 0x1
        static let efMayShareBlocks: UInt64 = 0x1
        static let efIsPurgeable: UInt64 = 0x8
        static let sfDataless: UInt32 = 0x4000_0000
        static let vDir: UInt32 = 2
    }

    private struct Entry {
        var name: String
        var isDir = false
        var dev: Int32 = 0
        var stFlags: UInt32 = 0
        var mountStatus: UInt32 = 0
        var linkCount: UInt32 = 1
        var alloc: UInt64 = 0
        var priv: UInt64?
        var fileID: UInt64 = 0
        var ext: UInt64 = 0
        var error: UInt32 = 0
    }

    func scan() throws -> FlatTree {
        BulkScanner.disableDatalessMaterialization()

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else { throw ScanError.cannotOpenRoot(rootPath, errno) }
        let rootDev = rootStat.st_dev

        let tree = FlatTree(rootPath: rootPath)
        tree.append(name: rootPath, parent: -1, size: 0, privateSize: 0, flags: .directory, files: 0)

        var stack: [(Int, String)] = [(0, rootPath)]
        var seenLinks = Set<UInt64>()
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var al = attrlist()
        al.bitmapcount = A.bitmapCount
        al.commonattr = A.cmnReturned | A.cmnName | A.cmnError | A.cmnDevID | A.cmnObjType | A.cmnFlags | A.cmnFileID
        al.dirattr = A.dirMountStatus
        al.fileattr = A.fileLinkCount | A.fileAllocSize
        al.forkattr = A.extPrivateSize | A.extFlags

        var visitedSinceUpdate = 0
        var bytesSinceUpdate: UInt64 = 0

        while let (dirIndex, dirPath) = stack.popLast() {
            if isCancelled { break }
            let fd = open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                tree.addFlags(.unreadable, at: dirIndex)
                continue
            }
            var aggSize: UInt64 = 0, aggPriv: UInt64 = 0, aggCount: UInt32 = 0

            readLoop: while true {
                let n = getattrlistbulk(fd, &al, buf, bufSize, A.optCmnExtended)
                if n < 0 { tree.addFlags(.unreadable, at: dirIndex); break }
                if n == 0 { break }
                var cursor = buf
                for _ in 0..<n {
                    let entry = BulkScanner.parse(cursor)
                    cursor += Int(cursor.loadUnaligned(as: UInt32.self))
                    visitedSinceUpdate += 1
                    if entry.error != 0 { continue }

                    if entry.isDir {
                        var f: NodeFlags = .directory
                        let childPath = dirPath == "/" ? "/" + entry.name : dirPath + "/" + entry.name
                        let crossesDevice = entry.dev != rootDev || (entry.mountStatus & A.mntStatusMountPoint) != 0
                            || excludedPaths.contains(childPath)
                        if crossesDevice { f.insert(.otherDevice) }
                        if entry.stFlags & A.sfDataless != 0 { f.insert(.dataless) }
                        let child = tree.append(name: entry.name, parent: dirIndex, size: 0, privateSize: 0, flags: f, files: 0)
                        if !crossesDevice && !f.contains(.dataless) {
                            stack.append((child, childPath))
                        }
                        continue
                    }

                    // A second name for a file already counted adds no bytes; skip it.
                    if entry.linkCount > 1 && !seenLinks.insert(entry.fileID).inserted { continue }
                    let size = entry.alloc
                    let priv = entry.priv ?? entry.alloc
                    var f: NodeFlags = []
                    if entry.ext & A.efMayShareBlocks != 0 { f.insert(.mayShareBlocks) }
                    if entry.ext & A.efIsPurgeable != 0 { f.insert(.purgeable) }
                    if entry.stFlags & A.sfDataless != 0 { f.insert(.dataless) }
                    bytesSinceUpdate &+= size

                    if size < aggregateBelow && !f.contains(.dataless) {
                        aggSize &+= size; aggPriv &+= priv; aggCount += 1
                    } else {
                        tree.append(name: entry.name, parent: dirIndex, size: size, privateSize: priv, flags: f, files: 1)
                    }
                }
                if visitedSinceUpdate >= 4096 {
                    let v = visitedSinceUpdate, b = bytesSinceUpdate
                    state.withLock { $0.itemsVisited += v; $0.bytesSeen &+= b }
                    visitedSinceUpdate = 0; bytesSinceUpdate = 0
                    if isCancelled { break readLoop }
                }
            }
            close(fd)
            if aggCount > 0 {
                let label = aggCount == 1 ? "1 smaller file" : "\(aggCount) smaller files"
                tree.append(name: "(\(label))", parent: dirIndex, size: aggSize, privateSize: aggPriv,
                            flags: .aggregate, files: aggCount)
            }
        }
        let v = visitedSinceUpdate, b = bytesSinceUpdate
        state.withLock { $0.itemsVisited += v; $0.bytesSeen &+= b }
        tree.finish()
        return tree
    }

    /// Parses one getattrlistbulk entry. Attributes appear in bitmap order, each 4-byte aligned.
    private static func parse(_ start: UnsafeMutableRawPointer) -> Entry {
        var p = start + 4 // skip entry length
        let returned = (
            common: p.loadUnaligned(as: UInt32.self),
            dir: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self),
            file: p.loadUnaligned(fromByteOffset: 12, as: UInt32.self),
            fork: p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        )
        p += 20 // attribute_set_t
        var e = Entry(name: "")
        if returned.common & A.cmnError != 0 {
            e.error = p.loadUnaligned(as: UInt32.self); p += 4
        }
        if returned.common & A.cmnName != 0 {
            let off = p.loadUnaligned(as: Int32.self)
            let len = p.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let namePtr = (p + Int(off)).assumingMemoryBound(to: UInt8.self)
            let byteCount = max(Int(len) - 1, 0) // length includes the trailing NUL
            e.name = String(decoding: UnsafeBufferPointer(start: namePtr, count: byteCount), as: UTF8.self)
            p += 8
        }
        if returned.common & A.cmnDevID != 0 { e.dev = p.loadUnaligned(as: Int32.self); p += 4 }
        if returned.common & A.cmnObjType != 0 {
            e.isDir = p.loadUnaligned(as: UInt32.self) == A.vDir; p += 4
        }
        if returned.common & A.cmnFlags != 0 { e.stFlags = p.loadUnaligned(as: UInt32.self); p += 4 }
        if returned.common & A.cmnFileID != 0 { e.fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
        if returned.dir & A.dirMountStatus != 0 { e.mountStatus = p.loadUnaligned(as: UInt32.self); p += 4 }
        if returned.file & A.fileLinkCount != 0 { e.linkCount = p.loadUnaligned(as: UInt32.self); p += 4 }
        if returned.file & A.fileAllocSize != 0 { e.alloc = UInt64(max(p.loadUnaligned(as: Int64.self), 0)); p += 8 }
        if returned.fork & A.extPrivateSize != 0 { e.priv = UInt64(max(p.loadUnaligned(as: Int64.self), 0)); p += 8 }
        if returned.fork & A.extFlags != 0 { e.ext = p.loadUnaligned(as: UInt64.self); p += 8 }
        return e
    }
}
