import XCTest

/// Temp directory with symlinks resolved by the kernel (/var -> /private/var).
/// Foundation's resolvingSymlinksInPath keeps the /var form, so it can't be used here.
private func realTemp() -> URL {
    let p = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(p) }
    return URL(fileURLWithPath: String(cString: p))
}

final class CoreTests: XCTestCase {

    // MARK: Treemap

    func testTreemapAreasAreProportionalAndInside() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let values: [Double] = [50, 25, 12, 8, 3, 2]
        let rects = TreemapLayout.layout(values: values, in: rect)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            XCTAssertEqual(Double(r.width * r.height), v / total * 120_000, accuracy: 1)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        // No overlaps.
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertLessThan(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height, 0.5)
            }
        }
    }

    func testTreemapHandlesZeros() {
        let rects = TreemapLayout.layout(values: [0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(rects, [.zero, .zero])
    }

    // MARK: FlatTree

    private func sampleTree() -> FlatTree {
        let t = FlatTree(rootPath: "/System/Volumes/Data")
        t.append(name: "/System/Volumes/Data", parent: -1, size: 0, privateSize: 0, flags: .directory, files: 0) // 0
        let users = t.append(name: "Users", parent: 0, size: 0, privateSize: 0, flags: .directory, files: 0)   // 1
        let me = t.append(name: "sandy", parent: users, size: 0, privateSize: 0, flags: .directory, files: 0)  // 2
        let lib = t.append(name: "Library", parent: me, size: 0, privateSize: 0, flags: .directory, files: 0)  // 3
        let msgs = t.append(name: "Messages", parent: lib, size: 0, privateSize: 0, flags: .directory, files: 0)
        t.append(name: "chat.db", parent: msgs, size: 1000, privateSize: 1000, flags: [], files: 1)
        t.append(name: "cache.bin", parent: lib, size: 300, privateSize: 300, flags: [], files: 1)
        let docs = t.append(name: "Documents", parent: me, size: 0, privateSize: 0, flags: .directory, files: 0)
        t.append(name: "big.mov", parent: docs, size: 500, privateSize: 100, flags: .mayShareBlocks, files: 1)
        let hidden = t.append(name: ".cache", parent: me, size: 0, privateSize: 0, flags: .directory, files: 0)
        t.append(name: "x", parent: hidden, size: 70, privateSize: 70, flags: [], files: 1)
        let other = t.append(name: "guest", parent: users, size: 0, privateSize: 0, flags: .directory, files: 0)
        t.append(name: "f", parent: other, size: 9, privateSize: 9, flags: [], files: 1)
        let apps = t.append(name: "Applications", parent: 0, size: 0, privateSize: 0, flags: .directory, files: 0)
        t.append(name: "Xcode.app", parent: apps, size: 4000, privateSize: 4000, flags: [], files: 1)
        t.append(name: "Notes.app", parent: apps, size: 40, privateSize: 40, flags: [], files: 1)
        t.finish()
        return t
    }

    func testFlatTreeTotalsAndPaths() {
        let t = sampleTree()
        XCTAssertEqual(t.total[0], 1000 + 300 + 500 + 70 + 9 + 4000 + 40)
        XCTAssertEqual(t.totalPrivate[0], 1000 + 300 + 100 + 70 + 9 + 4000 + 40)
        XCTAssertEqual(t.path(of: 4), "/System/Volumes/Data/Users/sandy/Library/Messages")
        XCTAssertEqual(t.index(ofPath: "/System/Volumes/Data/Users/sandy/Library"), 3)
        XCTAssertNil(t.index(ofPath: "/System/Volumes/Data/nope"))
    }

    func testFlatTreeRoundTrip() throws {
        let t = sampleTree()
        let d = try FlatTree.decode(t.encoded())
        XCTAssertEqual(d.count, t.count)
        XCTAssertEqual(d.names, t.names)
        XCTAssertEqual(d.total, t.total)
        XCTAssertEqual(d.flags, t.flags)
        XCTAssertEqual(d.rootPath, t.rootPath)
    }

    func testFlatTreeRejectsGarbage() {
        XCTAssertThrowsError(try FlatTree.decode(Data([1, 2, 3])))
        var bad = sampleTree().encoded()
        bad.removeLast(5)
        XCTAssertThrowsError(try FlatTree.decode(bad))
    }

    // MARK: Rules

    func testClassification() throws {
        let json = """
        { "rules": [
          { "path": "/Applications", "category": "applications", "info": "a", "safety": "user-data" },
          { "path": "/Applications/Xcode*.app", "category": "developer", "info": "x", "safety": "user-data" },
          { "path": "/Users/*", "category": "otherUsers", "info": "o", "safety": "user-data" },
          { "path": "~", "category": "documents", "info": "h", "safety": "user-data" },
          { "path": "~/*", "category": "documents", "info": "d", "safety": "user-data" },
          { "path": "~/.*", "category": "systemData", "info": "hidden", "safety": "app-data" },
          { "path": "~/Library", "category": "systemData", "info": "lib", "safety": "app-data" },
          { "path": "~/Library/Messages", "category": "messages", "info": "m", "safety": "user-data" }
        ] }
        """
        let rules = try RuleSet.decode(Data(json.utf8), homeRelative: "/Users/sandy")
        let t = sampleTree()
        let idx = CategoryIndex(tree: t, rules: rules)
        XCTAssertEqual(idx.totals[.messages], 1000)
        XCTAssertEqual(idx.totals[.systemData], 300 + 70)
        XCTAssertEqual(idx.totals[.documents], 500)
        XCTAssertEqual(idx.totals[.otherUsers], 9)
        XCTAssertEqual(idx.totals[.developer], 4000)
        XCTAssertEqual(idx.totals[.applications], 40)
        let sd = idx.sizes(for: .systemData)
        XCTAssertEqual(sd[0], 370)
        XCTAssertEqual(sd[3], 300) // Library minus Messages
    }

    // MARK: SafeDeleter

    func testSafeDeleterDoesNotFollowSymlinks() throws {
        let fm = FileManager.default
        let base = realTemp().appendingPathComponent("sdl-test-\(UUID().uuidString)")
        let target = base.appendingPathComponent("target")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: target.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("precious.txt"))
        try Data("x".utf8).write(to: target.appendingPathComponent("sub/a.txt"))
        try Data("y".utf8).write(to: target.appendingPathComponent("b.txt"))
        try fm.createSymbolicLink(at: target.appendingPathComponent("link"), withDestinationURL: outside)
        defer { try? fm.removeItem(at: base) }

        let r = SafeDeleter.removeContents(of: target.path)
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures)")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), [])
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("precious.txt").path))
    }

    func testSafeDeleterRefusesSymlinkedRoot() throws {
        let fm = FileManager.default
        let base = realTemp().appendingPathComponent("sdl-test-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: real.appendingPathComponent("precious.txt"))
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let r = SafeDeleter.removeContents(of: link.path)
        XCTAssertFalse(r.failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: real.appendingPathComponent("precious.txt").path))
    }

    func testSafeDeleterKeepAndOnly() throws {
        let fm = FileManager.default
        let base = realTemp().appendingPathComponent("sdl-test-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        for n in ["com.apple.x", "keep.me", "del.me"] { try Data("1".utf8).write(to: base.appendingPathComponent(n)) }
        defer { try? fm.removeItem(at: base) }
        _ = SafeDeleter.removeContents(of: base.path, keepTopLevel: { $0.hasPrefix("com.apple.") || $0 == "keep.me" })
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: base.path)), ["com.apple.x", "keep.me"])
    }

    // MARK: Scanner

    func testScannerCountsHardLinksOnceAndAggregates() throws {
        let fm = FileManager.default
        let base = realTemp().appendingPathComponent("sdl-scan-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("d"), withIntermediateDirectories: true)
        let big = Data(repeating: 7, count: 3 << 20)
        try big.write(to: base.appendingPathComponent("d/big.bin"))
        try fm.linkItem(at: base.appendingPathComponent("d/big.bin"), to: base.appendingPathComponent("hard.bin"))
        for i in 0..<5 { try Data("s\(i)".utf8).write(to: base.appendingPathComponent("small\(i)")) }
        defer { try? fm.removeItem(at: base) }

        let tree = try BulkScanner(rootPath: base.path).scan()
        let bigIndex = try XCTUnwrap(tree.index(ofPath: base.path + "/d/big.bin") ?? tree.index(ofPath: base.path + "/hard.bin"))
        XCTAssertGreaterThanOrEqual(tree.total[bigIndex], 3 << 20)
        // The hard link pair counts once.
        XCTAssertLessThan(tree.total[0], UInt64(2 * (3 << 20)))
        XCTAssertTrue(tree.children(of: 0).contains { tree.nodeFlags(Int($0)).contains(.aggregate) && tree.fileCount[Int($0)] == 5 })
    }
}
