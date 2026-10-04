import Darwin
import Foundation

/// Cleanup targets the app runs as the logged-in user. Nothing here needs root.
enum UserCleanup {
    static var home: String { NSHomeDirectory() }

    /// Environment for user-side tools: a predictable PATH and nothing inherited.
    static var toolEnvironment: [String: String] {
        [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
        ]
    }

    static func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// One directory whose contents a target clears.
    private struct DirSpec {
        var path: String
        var only: Set<String>? = nil
        var keep: (String) -> Bool = { _ in false }
    }

    private static let homebrewCacheName = "Homebrew"

    private static func dirSpecs(for id: String) -> [DirSpec] {
        let h = home
        switch id {
        case "user.caches":
            return [DirSpec(path: h + "/Library/Caches", keep: { $0.hasPrefix("com.apple.") || $0 == homebrewCacheName })]
        case "user.apple-caches":
            return [DirSpec(path: h + "/Library/Caches", keep: { !$0.hasPrefix("com.apple.") })]
        case "user.dot-cache":
            return [DirSpec(path: h + "/.cache")]
        case "user.logs":
            return [DirSpec(path: h + "/Library/Logs")]
        case "user.deriveddata":
            return [DirSpec(path: h + "/Library/Developer/Xcode/DerivedData")]
        case "user.devicesupport":
            return ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map {
                DirSpec(path: h + "/Library/Developer/Xcode/\($0) DeviceSupport")
            }
        case "user.archives":
            return [DirSpec(path: h + "/Library/Developer/Xcode/Archives")]
        case "user.coresim-caches":
            return [DirSpec(path: h + "/Library/Developer/CoreSimulator/Caches")]
        case "user.drivefs-canceled":
            let base = h + "/Library/Application Support/Google/DriveFS/canceled_uploads"
            let accounts = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
            return accounts.map { DirSpec(path: base + "/" + $0) }
        case "user.claude-sessions":
            return [DirSpec(path: h + "/Library/Application Support/Claude/local-agent-mode-sessions")]
        case "user.trash":
            return [DirSpec(path: h + "/.Trash")]
        case "user.temp-cache":
            return [DirSpec(path: darwinUserCacheDir())].filter { !$0.path.isEmpty }
        default:
            if id.hasPrefix("user.ios-backup.") {
                let name = String(id.dropFirst("user.ios-backup.".count))
                guard isSafeName(name) else { return [] }
                return [DirSpec(path: h + "/Library/Application Support/MobileSync/Backup", only: [name])]
            }
            return []
        }
    }

    private struct CommandSpec { var path: String; var args: [String]; var display: String; var timeout: TimeInterval }

    private static func commandSpec(for id: String) -> CommandSpec? {
        switch id {
        case "user.npm":
            guard let npm = tool("npm") else { return nil }
            return CommandSpec(path: npm, args: ["cache", "clean", "--force"], display: "npm cache clean --force", timeout: 300)
        case "user.pnpm":
            guard let pnpm = tool("pnpm") else { return nil }
            return CommandSpec(path: pnpm, args: ["store", "prune"], display: "pnpm store prune", timeout: 600)
        case "user.brew":
            guard let brew = tool("brew") else { return nil }
            return CommandSpec(path: brew, args: ["cleanup", "--prune=all", "-s"], display: "brew cleanup --prune=all -s", timeout: 900)
        case "user.sim-unavailable":
            return CommandSpec(path: "/usr/bin/xcrun", args: ["simctl", "delete", "unavailable"],
                               display: "xcrun simctl delete unavailable", timeout: 300)
        default:
            if id.hasPrefix("user.sim-runtime.") {
                let rid = String(id.dropFirst("user.sim-runtime.".count))
                guard isSafeName(rid) else { return nil }
                return CommandSpec(path: "/usr/bin/xcrun", args: ["simctl", "runtime", "delete", rid],
                                   display: "xcrun simctl runtime delete \(rid)", timeout: 600)
            }
            return nil
        }
    }

    /// IDs and names that come from directory listings or tool output are used as single
    /// path components or arguments only.
    private static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("/") && s != "." && s != ".." && !s.hasPrefix("-")
    }

    static func darwinUserCacheDir() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        guard n > 0 else { return "" }
        // confstr returns a /var/... path; /var is a symlink, which SafeDeleter refuses.
        guard let real = realpath(buf, nil) else { return "" }
        defer { free(real) }
        return String(cString: real)
    }

    // MARK: - Listing

    static func list() -> [CleanupTarget] {
        var out: [CleanupTarget] = []
        func dirTarget(_ id: String, group: String, title: String, detail: String, on: Bool) {
            let specs = dirSpecs(for: id)
            var bytes: UInt64 = 0
            var preview: [String] = []
            for s in specs {
                let m = SafeDeleter.measureContents(of: s.path, onlyTopLevel: s.only, keepTopLevel: s.keep)
                bytes &+= m.bytes
                preview += m.preview
            }
            guard bytes > 0 else { return }
            out.append(CleanupTarget(id: id, group: group, title: title, detail: detail, executor: .user,
                                     defaultSelected: on, irreversible: true, estimatedBytes: bytes,
                                     preview: Array(preview.prefix(40)), command: nil))
        }

        dirTarget("user.caches", group: "Caches", title: "App caches (~/Library/Caches)",
                  detail: "Caches apps rebuild on their own. Apple's own caches and Homebrew's are listed separately. Quit busy apps first.", on: true)
        dirTarget("user.apple-caches", group: "Caches", title: "Apple app caches (com.apple.* in ~/Library/Caches)",
                  detail: "Caches of Apple apps and services. Some are in use while you are logged in and will be skipped.", on: false)
        dirTarget("user.dot-cache", group: "Caches", title: "Command-line tool caches (~/.cache)",
                  detail: "Caches of command-line tools. Rebuilt or re-downloaded when needed.", on: true)
        dirTarget("user.temp-cache", group: "Caches", title: "Per-user system cache folder",
                  detail: "macOS's per-user cache folder in /private/var/folders. Apps running now may misbehave until relaunched.", on: false)
        dirTarget("user.logs", group: "Logs", title: "App logs (~/Library/Logs)",
                  detail: "Logs and crash reports apps wrote for you.", on: true)
        dirTarget("user.deriveddata", group: "Developer", title: "Xcode DerivedData",
                  detail: "Build products. Rebuilt on the next build.", on: true)
        dirTarget("user.devicesupport", group: "Developer", title: "Xcode device support files",
                  detail: "Debug symbols copied from each device you connected. Copied again the next time you connect it.", on: true)
        dirTarget("user.archives", group: "Developer", title: "Xcode archives",
                  detail: "Archived app builds. Needed to read crash reports from those versions.", on: false)
        dirTarget("user.coresim-caches", group: "Developer", title: "Simulator caches",
                  detail: "CoreSimulator caches. Rebuilt as needed.", on: true)

        if FileManager.default.fileExists(atPath: home + "/Library/Developer/CoreSimulator/Devices"),
           FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            out.append(CleanupTarget(id: "user.sim-unavailable", group: "Developer",
                                     title: "Simulators for runtimes that are no longer installed",
                                     detail: "Removes simulator devices whose iOS version is gone.", executor: .user,
                                     defaultSelected: true, irreversible: true, estimatedBytes: nil, preview: [],
                                     command: "xcrun simctl delete unavailable"))
        }
        out += simulatorRuntimes()

        if let npm = tool("npm") {
            _ = npm
            let m = SafeDeleter.measureContents(of: home + "/.npm/_cacache")
            out.append(CleanupTarget(id: "user.npm", group: "Package managers", title: "npm download cache",
                                     detail: "Packages npm downloaded. Fetched again when needed.", executor: .user,
                                     defaultSelected: true, irreversible: true, estimatedBytes: m.bytes, preview: [],
                                     command: "npm cache clean --force"))
        }
        if tool("pnpm") != nil {
            out.append(CleanupTarget(id: "user.pnpm", group: "Package managers", title: "Unused pnpm packages",
                                     detail: "Removes packages in the pnpm store that no project uses.", executor: .user,
                                     defaultSelected: true, irreversible: true, estimatedBytes: nil, preview: [],
                                     command: "pnpm store prune"))
        }
        if let brew = tool("brew") {
            let dry = Command.run(brew, ["cleanup", "--prune=all", "-s", "-n"], environment: toolEnvironment, timeout: 120)
            out.append(CleanupTarget(id: "user.brew", group: "Package managers", title: "Old Homebrew versions and downloads",
                                     detail: "Removes outdated package versions and cached downloads.", executor: .user,
                                     defaultSelected: true, irreversible: true, estimatedBytes: parseBrewEstimate(dry.output),
                                     preview: Array(dry.output.split(separator: "\n").prefix(40).map(String.init)),
                                     command: "brew cleanup --prune=all -s"))
        }

        dirTarget("user.drivefs-canceled", group: "Leftovers", title: "Google Drive cancelled uploads",
                  detail: "Copies Google Drive keeps when an upload is cancelled. Check the files are in Drive before removing them.", on: false)
        dirTarget("user.claude-sessions", group: "Leftovers", title: "Old Claude agent session folders",
                  detail: "Working folders from earlier Claude desktop agent sessions. Older sessions may disappear from the app's history.", on: false)
        out += iosBackups()
        dirTarget("user.trash", group: "Trash", title: "Empty the Trash",
                  detail: "Deletes everything in your Trash for good.", on: false)
        return out
    }

    private static func simulatorRuntimes() -> [CleanupTarget] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return [] }
        let out = Command.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], environment: toolEnvironment, timeout: 60)
        guard out.status == 0, let data = out.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.compactMap { key, value in
            guard isSafeName(key) else { return nil }
            let platform = value["platformIdentifier"] as? String ?? ""
            let version = value["version"] as? String ?? ""
            let build = value["build"] as? String ?? ""
            let name = platform.replacingOccurrences(of: "com.apple.platform.", with: "")
            let size = (value["sizeBytes"] as? NSNumber)?.uint64Value
            return CleanupTarget(id: "user.sim-runtime.\(key)", group: "Developer",
                                 title: "Simulator runtime \(name) \(version) (\(build))",
                                 detail: "A simulator runtime image. Xcode can download it again.", executor: .user,
                                 defaultSelected: false, irreversible: true, estimatedBytes: size, preview: [],
                                 command: "xcrun simctl runtime delete \(key)")
        }
    }

    private static func iosBackups() -> [CleanupTarget] {
        let base = home + "/Library/Application Support/MobileSync/Backup"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return names.filter(isSafeName).compactMap { name in
            let info = NSDictionary(contentsOfFile: base + "/" + name + "/Info.plist")
            let device = info?["Device Name"] as? String ?? "Unknown device"
            let date = (info?["Last Backup Date"] as? Date).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown date"
            let m = SafeDeleter.measureContents(of: base, onlyTopLevel: [name])
            guard m.bytes > 0 else { return nil }
            return CleanupTarget(id: "user.ios-backup.\(name)", group: "iOS backups",
                                 title: "Backup of \(device), \(date)",
                                 detail: "A local iPhone or iPad backup. Gone for good once removed.", executor: .user,
                                 defaultSelected: false, irreversible: true, estimatedBytes: m.bytes,
                                 preview: [base + "/" + name], command: nil)
        }
    }

    /// Parses "This operation would free approximately 1.2GB of disk space."
    static func parseBrewEstimate(_ text: String) -> UInt64? {
        guard let r = text.range(of: #"approximately ([0-9.]+)([KMGT]?B)"#, options: .regularExpression) else { return nil }
        let match = String(text[r]).replacingOccurrences(of: "approximately ", with: "")
        let units: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
        let num = Double(match.prefix { "0123456789.".contains($0) }) ?? 0
        let unit = String(match.drop { "0123456789.".contains($0) })
        return UInt64(num * (units[unit] ?? 1))
    }

    // MARK: - Running

    static func run(id: String) -> CleanupTargetResult {
        var result = CleanupTargetResult(targetID: id, freedBytes: 0, removed: 0, failed: 0, failures: [], output: nil)
        if let cmd = commandSpec(for: id) {
            let out = Command.run(cmd.path, cmd.args, environment: toolEnvironment, timeout: cmd.timeout)
            result.output = "$ \(cmd.display)\n" + out.output
            if out.status == 0 { result.removed = 1 } else { result.failed = 1 }
            return result
        }
        let specs = dirSpecs(for: id)
        guard !specs.isEmpty else {
            result.failed = 1
            result.output = "Unknown target."
            return result
        }
        for s in specs {
            let r = SafeDeleter.removeContents(of: s.path, onlyTopLevel: s.only, keepTopLevel: s.keep, requiredOwner: getuid())
            result.removed += r.removed
            result.freedBytes &+= r.freedBytes
            result.failed += r.failures.count
            result.failures += r.failures.prefix(50).map { CleanupItemResult(path: $0.path, ok: false, message: $0.reason) }
        }
        return result
    }
}
