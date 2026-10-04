import Foundation

enum TreeID: String, Hashable { case data, system, preboot }

/// One row in a browser list or one rectangle in the treemap.
struct BrowserItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case tree(TreeID, Int)
        case virtual(String)
    }
    var id: String
    var kind: Kind
    var name: String
    var size: UInt64
    var isContainer: Bool
    var flags: NodeFlags = []
    var note: String? = nil

    static func == (a: BrowserItem, b: BrowserItem) -> Bool { a.id == b.id && a.size == b.size }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// What a browser shows: a category (filtered Data-volume tree plus extra rows) or a raw tree.
enum BrowserScope: Hashable {
    case category(StorageCategory)
    case raw(TreeID)

    var title: String {
        switch self {
        case .category(let c): return c.title
        case .raw(.data): return "Data volume"
        case .raw(.system): return "macOS system volume"
        case .raw(.preboot): return "Preboot volume"
        }
    }
}

/// Builds rows for a scope from the model's scanned trees.
@MainActor
struct Browser {
    let model: AppModel
    let scope: BrowserScope

    private var filter: StorageCategory? {
        if case .category(let c) = scope { return c }
        return nil
    }

    private func tree(_ id: TreeID) -> FlatTree? {
        switch id {
        case .data: return model.data?.tree
        case .system: return model.system?.tree
        case .preboot: return model.preboot?.tree
        }
    }

    private func sizes(_ id: TreeID) -> [UInt64]? {
        guard let t = tree(id) else { return nil }
        if id == .data, let filter, let index = model.index { return index.sizes(for: filter) }
        return t.total
    }

    func roots() -> [BrowserItem] {
        switch scope {
        case .raw(let id):
            return treeChildren(id, of: 0)
        case .category(.macOS):
            return macOSRoots()
        case .category(.systemData):
            return systemDataRoots()
        case .category:
            return treeChildren(.data, of: 0)
        }
    }

    func children(of item: BrowserItem) -> [BrowserItem] {
        switch item.kind {
        case .tree(let id, let i):
            return treeChildren(id, of: i)
        case .virtual("system-volume"):
            return treeChildren(.system, of: 0)
        case .virtual("preboot-volume"):
            return treeChildren(.preboot, of: 0)
        case .virtual:
            return []
        }
    }

    /// Children of a tree node with sizes for this scope, largest first. Chains of
    /// single-child folders are collapsed into one row ("Users/sandy/Library").
    func treeChildren(_ id: TreeID, of i: Int) -> [BrowserItem] {
        guard let t = tree(id), let s = sizes(id), i < t.count else { return [] }
        var items: [BrowserItem] = []
        for c in t.children(of: i) {
            var node = Int(c)
            guard s[node] > 0 || filter == nil else { continue }
            var name = t.names[node]
            // Collapse chains.
            while t.nodeFlags(node).contains(.directory) {
                let kids = t.children(of: node).filter { s[Int($0)] > 0 }
                guard kids.count == 1, t.nodeFlags(Int(kids[0])).contains(.directory) else { break }
                node = Int(kids[0])
                name += "/" + t.names[node]
            }
            let f = t.nodeFlags(node)
            let container = f.contains(.directory) && !t.children(of: node).isEmpty
            items.append(BrowserItem(id: "\(id.rawValue):\(node)", kind: .tree(id, node), name: name,
                                     size: s[node], isContainer: container, flags: f))
        }
        return items.sorted { $0.size > $1.size }
    }

    private func macOSRoots() -> [BrowserItem] {
        guard let v = model.volumes else { return [] }
        var items: [BrowserItem] = []
        if let sys = v.system {
            items.append(BrowserItem(id: "v:system", kind: .virtual("system-volume"), name: "Sealed system volume (\(sys.name))",
                                     size: sys.consumed, isContainer: model.system != nil,
                                     note: "The read-only, cryptographically sealed copy of macOS. Its size is fixed by the macOS version."))
        }
        if let pre = v.preboot {
            items.append(BrowserItem(id: "v:preboot", kind: .virtual("preboot-volume"), name: "Preboot volume",
                                     size: pre.consumed, isContainer: model.preboot != nil,
                                     note: "Boot files and cryptexes: the Rosetta 2 runtime, the OS cryptex Apple patches separately, and staged updates. Folder sizes inside can add up to more than the volume because cryptex images share blocks."))
        }
        if let rec = v.recovery {
            items.append(BrowserItem(id: "v:recovery", kind: .virtual("recovery"), name: "Recovery volume",
                                     size: rec.consumed, isContainer: false, note: "recoveryOS, used for reinstalling and repairing macOS."))
        }
        if let t = model.data?.tree, let idx = t.index(ofPath: AppModel.dataRoot + "/System"), let index = model.index {
            let s = index.sizes(for: .macOS)
            items.append(BrowserItem(id: "data:\(idx)", kind: .tree(.data, idx), name: "macOS files on the Data volume (/System)",
                                     size: s[idx], isContainer: true, flags: .directory))
        }
        return items.sorted { $0.size > $1.size }
    }

    private func systemDataRoots() -> [BrowserItem] {
        var items = treeChildren(.data, of: 0)
        if let vm = model.volumes?.vm, vm.consumed > 0 {
            items.append(BrowserItem(id: "v:vm", kind: .virtual("vm"), name: "Swap files (VM volume)", size: vm.consumed,
                                     isContainer: false,
                                     note: "Memory macOS moved to disk. It shrinks after a restart or when memory pressure drops."))
        }
        if let u = model.dataUnexplained, u > 0 {
            var note = "Space the Data volume uses that the scan could not attribute to a file: APFS metadata, "
            note += "folders the scan could not read"
            if let snaps = model.volumes?.snapshotNames, !snaps.isEmpty {
                note += ", and \(snaps.count) local snapshot(s) holding deleted data"
            }
            note += "."
            items.append(BrowserItem(id: "v:unexplained", kind: .virtual("unexplained"), name: "Unexplained (metadata, snapshots, unreadable)",
                                     size: UInt64(u), isContainer: false, note: note))
        }
        return items.sorted { $0.size > $1.size }
    }

    // MARK: - Details for the inspector

    struct Details {
        var title: String
        var path: String?
        var displayPath: String?
        var size: UInt64
        var unsharedSize: UInt64?
        var files: UInt64?
        var flags: NodeFlags
        var info: String?
        var infoIsInherited = false
        var safety: Safety?
        var category: StorageCategory?
        var note: String?
        /// Whole-subtree size regardless of the category filter (what Trash would remove).
        var fullSize: UInt64?
        var isDirectory = false
    }

    func details(for item: BrowserItem) -> Details {
        var d = Details(title: item.name, size: item.size, flags: item.flags, note: item.note)
        guard case .tree(let id, let i) = item.kind, let t = tree(id) else { return d }
        var path = t.path(of: i)
        if t.nodeFlags(i).contains(.aggregate) { path = t.path(of: Int(t.parent[i])) }
        d.path = path
        d.displayPath = id == .data && path.hasPrefix(AppModel.dataRoot + "/")
            ? String(path.dropFirst(AppModel.dataRoot.count)) : path
        d.files = t.totalFiles[i]
        d.fullSize = t.total[i]
        d.isDirectory = t.nodeFlags(i).contains(.directory)
        // Only meaningful when the shown size is the whole subtree.
        if filter == nil, t.totalPrivate[i] < t.total[i] { d.unsharedSize = t.totalPrivate[i] }
        if id == .data, let index = model.index {
            d.category = StorageCategory.from(index: index.classification.categoryOf[i])
            if let r = index.rules.nearestRule(for: i, in: t, classification: index.classification) {
                d.info = r.rule.info
                d.infoIsInherited = !r.exact
                d.safety = r.rule.safety
            }
        }
        return d
    }
}
