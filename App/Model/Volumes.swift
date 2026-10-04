import Darwin
import Foundation

struct APFSVolumeInfo: Identifiable, Hashable {
    var id: String { device }
    var device: String
    var name: String
    var roles: [String]
    var consumed: UInt64
    var mountPoint: String?

    var roleSummary: String { roles.isEmpty ? "No role" : roles.joined(separator: ", ") }
}

/// Container- and volume-level numbers. None of this needs root.
struct VolumeReport {
    var containerDevice: String
    var capacity: UInt64
    var free: UInt64
    var volumes: [APFSVolumeInfo]
    var snapshotNames: [String]
    var swapUsed: UInt64
    var swapTotal: UInt64
    var sleepImage: UInt64
    var purgeable: UInt64

    func volume(role: String) -> APFSVolumeInfo? { volumes.first { $0.roles.contains(role) } }
    var system: APFSVolumeInfo? { volume(role: "System") }
    var data: APFSVolumeInfo? { volume(role: "Data") }
    var preboot: APFSVolumeInfo? { volume(role: "Preboot") }
    var recovery: APFSVolumeInfo? { volume(role: "Recovery") }
    var vm: APFSVolumeInfo? { volume(role: "VM") }
    var used: UInt64 { capacity > free ? capacity - free : 0 }

    static func load() -> VolumeReport? {
        guard let dataInfo = plist(["info", "-plist", "/System/Volumes/Data"]),
              let containerRef = dataInfo["APFSContainerReference"] as? String,
              let dataDevice = dataInfo["DeviceIdentifier"] as? String,
              let list = plist(["apfs", "list", "-plist"]),
              let containers = list["Containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["ContainerReference"] as? String == containerRef })
        else { return nil }

        let capacity = uint(container["CapacityCeiling"])
        let free = uint(container["CapacityFree"])
        var volumes: [APFSVolumeInfo] = []
        for v in container["Volumes"] as? [[String: Any]] ?? [] {
            let device = v["DeviceIdentifier"] as? String ?? "?"
            volumes.append(APFSVolumeInfo(
                device: device,
                name: v["Name"] as? String ?? device,
                roles: v["Roles"] as? [String] ?? [],
                consumed: uint(v["CapacityInUse"]),
                mountPoint: nil))
        }

        var snapshots: [String] = []
        if let snap = plist(["apfs", "listSnapshots", "-plist", dataDevice]),
           let list = snap["Snapshots"] as? [[String: Any]] {
            snapshots = list.compactMap { $0["SnapshotName"] as? String }
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        var sleep = stat()
        let sleepBytes: UInt64 = stat("/private/var/vm/sleepimage", &sleep) == 0 ? UInt64(sleep.st_blocks) * 512 : 0

        var purgeable: UInt64 = 0
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
           let important = values.volumeAvailableCapacityForImportantUsage,
           let plain = values.volumeAvailableCapacity, important > Int64(plain) {
            purgeable = UInt64(important - Int64(plain))
        }

        return VolumeReport(containerDevice: containerRef, capacity: capacity, free: free, volumes: volumes,
                            snapshotNames: snapshots, swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
                            sleepImage: sleepBytes, purgeable: purgeable)
    }

    private static func plist(_ args: [String]) -> [String: Any]? {
        let out = Command.run("/usr/sbin/diskutil", args, timeout: 30)
        guard out.status == 0, let data = out.output.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func uint(_ any: Any?) -> UInt64 {
        if let n = any as? NSNumber { return n.uint64Value }
        return 0
    }
}
