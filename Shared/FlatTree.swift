import Foundation

struct NodeFlags: OptionSet, Hashable {
    let rawValue: UInt8
    static let directory      = NodeFlags(rawValue: 1 << 0)
    /// Cloud placeholder (SF_DATALESS). Occupies almost nothing locally.
    static let dataless       = NodeFlags(rawValue: 1 << 1)
    /// APFS says this file may share blocks with a clone.
    static let mayShareBlocks = NodeFlags(rawValue: 1 << 2)
    /// The system may delete this file on its own when space runs low.
    static let purgeable      = NodeFlags(rawValue: 1 << 3)
    /// The directory could not be read (permissions, SIP, TCC).
    static let unreadable     = NodeFlags(rawValue: 1 << 4)
    /// A mount point or another device; not descended.
    static let otherDevice    = NodeFlags(rawValue: 1 << 5)
    /// Synthetic node standing for many small files in one directory.
    static let aggregate      = NodeFlags(rawValue: 1 << 6)
    /// A second hard link to a file already counted.
    static let hardLinkDup    = NodeFlags(rawValue: 1 << 7)
}

/// A scanned directory tree stored as flat arrays in preorder (every parent index is
/// lower than its children's). Index 0 is the scan root.
final class FlatTree {
    let rootPath: String
    private(set) var names: [String] = []
    private(set) var parent: [Int32] = []
    /// Allocated bytes of the node itself (0 for directories, the sum for aggregates).
    private(set) var ownSize: [UInt64] = []
    /// Allocated bytes not shared with clones (APFS private size), for files.
    private(set) var ownPrivate: [UInt64] = []
    /// Allocated bytes in files APFS marks purgeable (macOS may delete them on its own).
    private(set) var ownPurgeable: [UInt64] = []
    private(set) var flags: [UInt8] = []
    /// Number of files the node stands for (1 for a file, N for an aggregate, 0 for a directory).
    private(set) var fileCount: [UInt32] = []

    // Derived after `finish()` or decoding.
    private(set) var total: [UInt64] = []
    private(set) var totalPrivate: [UInt64] = []
    private(set) var totalPurgeable: [UInt64] = []
    private(set) var totalFiles: [UInt64] = []
    private var childStart: [Int32] = []
    private var childList: [Int32] = []

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    var count: Int { names.count }

    @discardableResult
    func append(name: String, parent p: Int, size: UInt64, privateSize: UInt64,
                flags f: NodeFlags, files: UInt32, purgeable: UInt64 = 0) -> Int {
        names.append(name)
        parent.append(Int32(p))
        ownSize.append(size)
        ownPrivate.append(privateSize)
        ownPurgeable.append(purgeable)
        flags.append(f.rawValue)
        fileCount.append(files)
        return names.count - 1
    }

    func addFlags(_ f: NodeFlags, at i: Int) {
        flags[i] |= f.rawValue
    }

    func nodeFlags(_ i: Int) -> NodeFlags { NodeFlags(rawValue: flags[i]) }

    /// Computes subtree totals and the child index. Call once after the last `append`.
    func finish() {
        let n = count
        total = ownSize
        totalPrivate = ownPrivate
        totalPurgeable = ownPurgeable
        totalFiles = fileCount.map { UInt64($0) }
        if n > 1 {
            for i in stride(from: n - 1, through: 1, by: -1) {
                let p = Int(parent[i])
                total[p] &+= total[i]
                totalPrivate[p] &+= totalPrivate[i]
                totalPurgeable[p] &+= totalPurgeable[i]
                totalFiles[p] &+= totalFiles[i]
            }
        }
        // CSR child index.
        var counts = [Int32](repeating: 0, count: n + 1)
        for i in 1..<max(n, 1) { counts[Int(parent[i]) + 1] += 1 }
        for i in 0..<n { counts[i + 1] += counts[i] }
        childStart = counts
        childList = [Int32](repeating: 0, count: max(n - 1, 0))
        var fill = counts
        for i in 1..<max(n, 1) {
            let p = Int(parent[i])
            childList[Int(fill[p])] = Int32(i)
            fill[p] += 1
        }
    }

    func children(of i: Int) -> ArraySlice<Int32> {
        guard i + 1 < childStart.count else { return [] }
        return childList[Int(childStart[i])..<Int(childStart[i + 1])]
    }

    func path(of i: Int) -> String {
        if i == 0 { return rootPath }
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(names[cur])
            cur = Int(parent[cur])
        }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    /// Finds the node for an absolute path inside this tree, or nil.
    func index(ofPath path: String) -> Int? {
        let base = rootPath == "/" ? "" : rootPath
        if path == rootPath { return 0 }
        guard path.hasPrefix(base + "/") else { return nil }
        let rel = path.dropFirst(base.count + 1)
        var cur = 0
        for comp in rel.split(separator: "/") {
            guard let next = children(of: cur).first(where: { names[Int($0)] == comp }) else { return nil }
            cur = Int(next)
        }
        return cur
    }

    // MARK: - Binary encoding

    private static let magic: UInt32 = 0x53444C33 // "SDL3"

    enum DecodeError: Error { case truncated, badMagic, inconsistent }

    func encoded() -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; d.append(Data(bytes: &le, count: MemoryLayout<T>.size)) }
        // All supported Macs are little-endian, so arrays are written as raw memory.
        func putArray<T: FixedWidthInteger>(_ a: [T]) {
            a.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        put(FlatTree.magic)
        let rootBytes = Data(rootPath.utf8)
        put(UInt32(rootBytes.count)); d.append(rootBytes)
        put(UInt64(count))
        var blob = Data()
        blob.reserveCapacity(count * 16)
        for n in names { blob.append(contentsOf: n.utf8); blob.append(0) }
        put(UInt64(blob.count)); d.append(blob)
        putArray(parent); putArray(ownSize); putArray(ownPrivate); putArray(ownPurgeable); putArray(fileCount)
        d.append(contentsOf: flags)
        return d
    }

    static func decode(_ d: Data) throws -> FlatTree {
        var off = 0
        func get<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard off + size <= d.count else { throw DecodeError.truncated }
            let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) }
            off += size
            return T(littleEndian: v)
        }
        func getArray<T: FixedWidthInteger>(_: T.Type, _ n: Int) throws -> [T] {
            let size = MemoryLayout<T>.size
            guard n >= 0, off <= d.count, n <= (d.count - off) / size else { throw DecodeError.truncated }
            var out = [T](repeating: 0, count: n)
            out.withUnsafeMutableBytes { dst in
                d.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[off ..< off + n * size]))
                }
            }
            off += n * size
            return out
        }
        guard try get(UInt32.self) == magic else { throw DecodeError.badMagic }
        let rootLen = Int(try get(UInt32.self))
        guard rootLen < 4096, rootLen <= d.count - off else { throw DecodeError.truncated }
        let root = String(decoding: d[d.startIndex + off ..< d.startIndex + off + rootLen], as: UTF8.self)
        off += rootLen
        guard let n = Int(exactly: try get(UInt64.self)) else { throw DecodeError.inconsistent }
        // Every node needs at least 26 bytes (name NUL, 4+8+8+8+4 array bytes, 1 flag byte).
        guard n > 0, n < 200_000_000, n <= (d.count - off) / 34 else { throw DecodeError.inconsistent }
        guard let blobLen = Int(exactly: try get(UInt64.self)) else { throw DecodeError.inconsistent }
        guard blobLen >= 0, blobLen <= d.count - off else { throw DecodeError.truncated }
        var names: [String] = []
        names.reserveCapacity(n)
        d.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + off
            var start = 0
            for i in 0..<blobLen where base[i] == 0 {
                names.append(String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self))
                start = i + 1
            }
        }
        off += blobLen
        guard names.count == n else { throw DecodeError.inconsistent }
        let tree = FlatTree(rootPath: root)
        tree.names = names
        tree.parent = try getArray(Int32.self, n)
        tree.ownSize = try getArray(UInt64.self, n)
        tree.ownPrivate = try getArray(UInt64.self, n)
        tree.ownPurgeable = try getArray(UInt64.self, n)
        tree.fileCount = try getArray(UInt32.self, n)
        guard n <= d.count - off else { throw DecodeError.truncated }
        tree.flags = [UInt8](d[d.startIndex + off ..< d.startIndex + off + n])
        guard tree.parent[0] == -1 else { throw DecodeError.inconsistent }
        for i in 1..<n where tree.parent[i] < 0 || Int(tree.parent[i]) >= i {
            throw DecodeError.inconsistent
        }
        tree.finish()
        return tree
    }
}
