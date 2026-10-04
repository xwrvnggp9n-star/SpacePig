import Darwin
import Foundation

/// The buckets System Settings > General > Storage shows, as this app reconstructs them.
enum StorageCategory: String, CaseIterable, Codable, Identifiable {
    case macOS, systemData, applications, documents, iCloudDrive, photos, messages, mail,
         music, tv, podcasts, books, musicCreation, developer, iOSFiles, trash, otherUsers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: return "macOS"
        case .systemData: return "System Data"
        case .applications: return "Applications"
        case .documents: return "Documents"
        case .iCloudDrive: return "iCloud Drive"
        case .photos: return "Photos"
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .music: return "Music"
        case .tv: return "TV"
        case .podcasts: return "Podcasts"
        case .books: return "Books"
        case .musicCreation: return "Music Creation"
        case .developer: return "Developer"
        case .iOSFiles: return "iOS Files"
        case .trash: return "Trash"
        case .otherUsers: return "Other Users & Shared"
        }
    }

    var symbol: String {
        switch self {
        case .macOS: return "laptopcomputer"
        case .systemData: return "ellipsis.circle"
        case .applications: return "square.grid.2x2"
        case .documents: return "doc"
        case .iCloudDrive: return "icloud"
        case .photos: return "photo"
        case .messages: return "message"
        case .mail: return "envelope"
        case .music: return "music.note"
        case .tv: return "tv"
        case .podcasts: return "antenna.radiowaves.left.and.right"
        case .books: return "book"
        case .musicCreation: return "pianokeys"
        case .developer: return "hammer"
        case .iOSFiles: return "iphone"
        case .trash: return "trash"
        case .otherUsers: return "person.2"
        }
    }

    var index: UInt8 { UInt8(StorageCategory.allCases.firstIndex(of: self)!) }
    static func from(index: UInt8) -> StorageCategory { allCases[Int(index)] }
}

enum Safety: String, Codable {
    case system, appData = "app-data", userData = "user-data", rebuilds, safe

    var title: String {
        switch self {
        case .system: return "Managed by macOS. Leave it alone."
        case .appData: return "App data. Removing it resets or breaks the app."
        case .userData: return "Your data. Remove only if you no longer need it."
        case .rebuilds: return "Rebuilt automatically. Safe to clear."
        case .safe: return "Safe to remove."
        }
    }
}

struct Rule: Decodable {
    var path: String
    var category: StorageCategory?
    var info: String
    var safety: Safety
}

private struct RuleFile: Decodable { var rules: [Rule] }

/// Result of matching rules against a Data-volume tree.
struct Classification {
    /// `StorageCategory.index` for every node.
    var categoryOf: [UInt8]
    /// Index into `RuleSet.rules` for nodes a rule names exactly, else -1.
    var ruleOf: [Int32]
}

/// Path rules compiled into a trie of path segments.
final class RuleSet {
    let rules: [Rule]
    private struct TrieNode {
        var literal: [String: Int] = [:]
        var globs: [(String, Int)] = []
        var rule: Int?
    }
    private var trie: [TrieNode] = [TrieNode()]

    /// - Parameter homeRelative: the user's home as a path on the Data volume, e.g. "/Users/sandy".
    init(rules: [Rule], homeRelative: String) {
        self.rules = rules
        for (i, rule) in rules.enumerated() {
            var path = rule.path
            if path == "~" { path = homeRelative } else if path.hasPrefix("~/") { path = homeRelative + path.dropFirst() }
            var node = 0
            for seg in path.split(separator: "/").map(String.init) {
                let isGlob = seg.contains("*") || seg.contains("?") || seg.contains("[")
                if isGlob {
                    if let existing = trie[node].globs.first(where: { $0.0 == seg }) {
                        node = existing.1
                    } else {
                        trie.append(TrieNode())
                        trie[node].globs.append((seg, trie.count - 1))
                        node = trie.count - 1
                    }
                } else if let next = trie[node].literal[seg] {
                    node = next
                } else {
                    trie.append(TrieNode())
                    trie[node].literal[seg] = trie.count - 1
                    node = trie.count - 1
                }
            }
            trie[node].rule = i // later rules overwrite earlier ones for the same path
        }
    }

    static func bundled(homeRelative: String) -> RuleSet {
        guard let url = Bundle.main.url(forResource: "rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RuleFile.self, from: data) else {
            return RuleSet(rules: [], homeRelative: homeRelative)
        }
        return RuleSet(rules: file.rules, homeRelative: homeRelative)
    }

    static func decode(_ data: Data, homeRelative: String) throws -> RuleSet {
        RuleSet(rules: try JSONDecoder().decode(RuleFile.self, from: data).rules, homeRelative: homeRelative)
    }

    func classify(_ tree: FlatTree, rootCategory: StorageCategory = .systemData) -> Classification {
        let n = tree.count
        var categoryOf = [UInt8](repeating: rootCategory.index, count: n)
        var ruleOf = [Int32](repeating: -1, count: n)
        var states: [Int: [Int]] = [0: [0]]
        guard n > 1 else { return Classification(categoryOf: categoryOf, ruleOf: ruleOf) }
        for i in 1..<n {
            let p = Int(tree.parent[i])
            categoryOf[i] = categoryOf[p]
            guard let parentStates = states[p] else { continue }
            let name = tree.names[i]
            var next: [Int] = []
            for s in parentStates {
                if let t = trie[s].literal[name] { next.append(t) }
                for (pattern, t) in trie[s].globs where fnmatch(pattern, name, 0) == 0 { next.append(t) }
            }
            guard !next.isEmpty else { continue }
            states[i] = next
            if let best = next.compactMap({ trie[$0].rule }).max() {
                ruleOf[i] = Int32(best)
                if let c = rules[best].category { categoryOf[i] = c.index }
            }
        }
        return Classification(categoryOf: categoryOf, ruleOf: ruleOf)
    }

    /// Rule that applies to a node: the node's own rule, else the nearest ancestor's.
    func nearestRule(for i: Int, in tree: FlatTree, classification: Classification) -> (rule: Rule, exact: Bool)? {
        var cur = i
        while cur >= 0 {
            let r = classification.ruleOf[cur]
            if r >= 0 { return (rules[Int(r)], cur == i) }
            cur = Int(tree.parent[cur])
        }
        return nil
    }
}

/// Category totals and per-category subtree sizes for one Data-volume tree.
final class CategoryIndex {
    let tree: FlatTree
    let classification: Classification
    let rules: RuleSet
    private(set) var totals: [StorageCategory: UInt64] = [:]
    private var filtered: [UInt8: [UInt64]] = [:]
    private let lock = NSLock()

    init(tree: FlatTree, rules: RuleSet) {
        self.tree = tree
        self.rules = rules
        self.classification = rules.classify(tree)
        var t = [UInt64](repeating: 0, count: StorageCategory.allCases.count)
        for i in 0..<tree.count {
            t[Int(classification.categoryOf[i])] &+= tree.ownSize[i]
        }
        for c in StorageCategory.allCases { totals[c] = t[Int(c.index)] }
    }

    /// Subtree sizes counting only bytes assigned to `category`.
    func sizes(for category: StorageCategory) -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        if let cached = filtered[category.index] { return cached }
        let n = tree.count
        var s = [UInt64](repeating: 0, count: n)
        let c = category.index
        for i in 0..<n where classification.categoryOf[i] == c { s[i] = tree.ownSize[i] }
        if n > 1 {
            for i in stride(from: n - 1, through: 1, by: -1) {
                s[Int(tree.parent[i])] &+= s[i]
            }
        }
        filtered[category.index] = s
        return s
    }
}
