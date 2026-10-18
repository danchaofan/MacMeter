import AppKit
import Foundation
import CSystem

enum MemoryPressure: String {
    case normal = "正常", warning = "偏高", critical = "严重", unknown = "读取中"
    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }
    init(level: Int32) {
        switch level { case 1: self = .normal; case 2: self = .warning; case 4: self = .critical; default: self = .unknown }
    }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double
}

struct ProcessReading {
    let pid: Int32
    let parent: Int32
    let start: UInt64
    let cpu: UInt64
    let memory: UInt64
    let path: String
}

struct ApplicationIdentity: Equatable {
    let pid: Int32
    let bundlePath: String
    let name: String
    let bundleID: String
    let launched: Date?

    var protected: Bool {
        pid == ProcessInfo.processInfo.processIdentifier ||
        ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.WindowManager"].contains(bundleID)
    }
}

struct AppUsage: Identifiable {
    var id: Int32 { identity.pid }
    let identity: ApplicationIdentity
    let cpu: Double?
    let memory: UInt64
    let processCount: Int
}

struct SampleResult {
    let raw: RBSystemSample
    let cpu: Double?
    let apps: [AppUsage]
    let timestamp: Date
    let processReadCount: Int
    let network: NetworkStatus
    let battery: BatteryStatus
}

enum ResourceSort: String, CaseIterable { case cpu = "CPU", memory = "内存" }
enum MenuStyle: String, CaseIterable { case both = "CPU + 内存", cpu = "仅 CPU", memory = "仅内存", network = "仅网速", battery = "仅电池", icon = "仅图标" }

enum Format {
    static func bytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return gib >= 1 ? String(format: "%.1f GB", gib) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func rate(_ value: Double?) -> String {
        guard let value = value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }
}

struct NetworkCounter {
    let id: String
    let name: String
    let received: UInt64
    let sent: UInt64
}

struct NetworkStatus {
    let download: Double?
    let upload: Double?
    let interfaces: [String]
    let available: Bool
    static let loading = NetworkStatus(download: nil, upload: nil, interfaces: [], available: false)
    var description: String {
        if !available { return "暂时无法读取" }
        return interfaces.isEmpty ? "无活动网络接口" : interfaces.joined(separator: "、")
    }
}

struct NetworkTracker {
    private var previous: [String: NetworkCounter]?
    private var previousTime: TimeInterval?

    mutating func sample(_ counters: [NetworkCounter]?, uptime: TimeInterval) -> NetworkStatus {
        guard let counters = counters else { previous = nil; previousTime = nil; return .loading }
        let now = Dictionary(counters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        defer { previous = now; previousTime = uptime }
        let interfaces = counters.map(\.name).sorted()
        guard let old = previous, let time = previousTime, uptime > time, uptime - time <= 15 else {
            return NetworkStatus(download: nil, upload: nil, interfaces: interfaces, available: true)
        }
        var download = 0.0, upload = 0.0
        for counter in now.values {
            guard let baseline = old[counter.id], counter.received >= baseline.received, counter.sent >= baseline.sent else { continue }
            download += Double(counter.received - baseline.received)
            upload += Double(counter.sent - baseline.sent)
        }
        return NetworkStatus(download: download / (uptime - time), upload: upload / (uptime - time), interfaces: interfaces, available: true)
    }
}

struct BatteryStatus {
    let available: Bool
    let present: Bool
    let percent: Double?
    let onAC: Bool
    let charging: Bool
    let charged: Bool
    let minutesRemaining: Int?
    let healthState: Int
    let maximumCapacity: Double?
    let capacityEstimated: Bool
    let cycleCount: Int?
    let designCapacity: Int?
    let fullCapacity: Int?

    init(raw: RBBatterySample) {
        available = raw.available == 1
        present = raw.present == 1
        percent = available && present && raw.max_capacity > 0 && raw.current_capacity >= 0
            ? min(100, max(0, Double(raw.current_capacity) / Double(raw.max_capacity) * 100)) : nil
        onAC = raw.on_ac == 1
        charging = raw.charging == 1
        charged = raw.charged == 1
        let time = charging ? raw.minutes_to_full : raw.minutes_to_empty
        minutesRemaining = available && present && time > 0 && (charging || !onAC) ? Int(time) : nil
        healthState = available && present ? Int(raw.health_state) : 0
        maximumCapacity = available && present && [1, 2].contains(raw.capacity_source) &&
            raw.maximum_capacity_percent.isFinite && (0...100).contains(raw.maximum_capacity_percent)
            ? raw.maximum_capacity_percent : nil
        capacityEstimated = raw.capacity_source == 2
        cycleCount = available && present && raw.cycle_count >= 0 ? Int(raw.cycle_count) : nil
        designCapacity = available && present && raw.design_capacity_mah > 100 ? Int(raw.design_capacity_mah) : nil
        fullCapacity = available && present && raw.full_capacity_mah > 100 ? Int(raw.full_capacity_mah) : nil
    }
    static let loading = BatteryStatus(raw: RBBatterySample())
    var healthDescription: String {
        switch healthState {
        case 1: return "正常"
        case 2: return "性能下降"
        case 3: return "建议维修"
        case 4: return "需要维修"
        default: return "系统未提供"
        }
    }
    var healthColor: NSColor {
        switch healthState {
        case 1: return .systemGreen
        case 2, 3: return .systemOrange
        case 4: return .systemRed
        default: return .secondaryLabelColor
        }
    }
    var state: String {
        if !available { return "暂时无法读取" }
        if !present { return "无内置电池" }
        if charged && onAC { return "已充满" }
        if charging { return "正在充电" }
        return onAC ? "已接电源 · 未充电" : "电池供电"
    }
    var timeDescription: String {
        guard available, present else { return "" }
        guard let minutes = minutesRemaining else { return charged && onAC ? "已连接电源" : onAC && !charging ? "充电可能已暂停" : "系统未提供时间估算" }
        let duration = minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
        return charging ? "约 \(duration)充满" : "预计可用 \(duration)"
    }
    var symbol: String {
        if !present { return "battery.0" }
        if charging { return "battery.100.bolt" }
        switch percent ?? 0 { case 87.5...: return "battery.100"; case 62.5..<87.5: return "battery.75"; case 37.5..<62.5: return "battery.50"; case 12.5..<37.5: return "battery.25"; default: return "battery.0" }
    }
}

struct CPUTracker {
    private var previous: [UInt64]?
    mutating func sample(_ raw: RBSystemSample) -> Double? {
        guard raw.cpu_valid == 1 else { previous = nil; return nil }
        let now = [raw.cpu_user, raw.cpu_system, raw.cpu_nice, raw.cpu_idle]
        defer { previous = now }
        guard let old = previous else { return nil }
        // Kernel CPU tick counters are 32-bit and wrap on long uptimes.
        let delta = zip(now, old).map { UInt64(UInt32(truncatingIfNeeded: $0.0) &- UInt32(truncatingIfNeeded: $0.1)) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return min(100, max(0, Double(total - delta[3]) / Double(total) * 100))
    }
}

final class ProcessTracker {
    private var previous: [Int32: ProcessReading] = [:]
    private var previousTime: TimeInterval?

    func sample(_ processes: [ProcessReading], applications: [ApplicationIdentity], uptime: TimeInterval, coreCount: Int) -> [AppUsage] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let appByPID = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let sortedPaths = applications.filter { !$0.bundlePath.isEmpty }.sorted { $0.bundlePath.count > $1.bundlePath.count }
        let elapsed = previousTime.map { uptime - $0 }
        var groups: [Int32: [ProcessReading]] = [:]
        for process in processes {
            var owner: ApplicationIdentity? = appByPID[process.pid]
            // Match nested helper bundles before walking ancestry: launchd may reparent helpers.
            if owner == nil { owner = sortedPaths.first { process.path.hasPrefix($0.bundlePath + "/") } }
            if owner == nil {
                var ancestor = process.parent
                var visited = Set<Int32>()
                while ancestor > 1 && visited.insert(ancestor).inserted {
                    if let app = appByPID[ancestor] { owner = app; break }
                    guard let parent = byPID[ancestor] else { break }
                    ancestor = parent.parent
                }
            }
            if let owner = owner { groups[owner.pid, default: []].append(process) }
        }
        let result = applications.compactMap { app -> AppUsage? in
            guard let members = groups[app.pid], !members.isEmpty else { return nil }
            var cpu: Double? = nil
            if let elapsed = elapsed, elapsed > 0 {
                // New or reused PIDs have no reliable interval; baseline them for one sample.
                var nanoseconds: UInt64 = 0
                var hasBaseline = false
                for member in members {
                    guard let old = previous[member.pid], old.start == member.start, member.cpu >= old.cpu else { continue }
                    hasBaseline = true
                    nanoseconds += member.cpu - old.cpu
                }
                if hasBaseline { cpu = min(100, Double(nanoseconds) / 1e9 / elapsed / Double(max(1, coreCount)) * 100) }
            }
            return AppUsage(identity: app, cpu: cpu, memory: members.reduce(0) { $0 + $1.memory }, processCount: members.count)
        }
        previous = byPID
        previousTime = uptime
        return result
    }
}

struct SustainedAlertGate {
    private var since: Date?
    private var lastAlert: Date?
    private var deliveredForEpisode = false

    mutating func update(active: Bool, enabled: Bool, now: Date, duration: TimeInterval, cooldown: TimeInterval = 600) -> Bool {
        guard active, enabled else { since = nil; deliveredForEpisode = false; return false }
        if since == nil { since = now }
        guard let start = since, now.timeIntervalSince(start) >= duration, !deliveredForEpisode else { return false }
        guard lastAlert.map({ now.timeIntervalSince($0) >= cooldown }) ?? true else { return false }
        lastAlert = now
        deliveredForEpisode = true
        return true
    }
    mutating func resetEpisode() { since = nil; deliveredForEpisode = false }
}
