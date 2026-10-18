import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications
import CSystem

final class SystemSampler {
    private let queue = DispatchQueue(label: "local.resourceboard.sampling", qos: .utility)
    private var cpu = CPUTracker()
    private var processes = ProcessTracker()
    private var network = NetworkTracker()
    private var lastUptime: TimeInterval?

    func sample(applications: [ApplicationIdentity], completion: @escaping (SampleResult) -> Void) {
        queue.async {
            let uptime = ProcessInfo.processInfo.systemUptime
            if let last = self.lastUptime, uptime - last > 15 {
                self.cpu = CPUTracker()
                self.processes = ProcessTracker()
                self.network = NetworkTracker()
            }
            self.lastUptime = uptime
            let system = rb_system_sample()
            var count: Int = 0
            let pointer = rb_process_samples(&count)
            var readings: [ProcessReading] = []
            if let pointer = pointer {
                readings.reserveCapacity(count)
                for index in 0..<count {
                    let raw = pointer[index]
                    let path = withUnsafeBytes(of: raw.path) { bytes in
                        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    readings.append(ProcessReading(pid: raw.pid, parent: raw.parent_pid, start: raw.start_time,
                                                   cpu: raw.cpu_nanoseconds, memory: raw.physical_bytes, path: path))
                }
                rb_free_process_samples(pointer)
            }
            let apps = self.processes.sample(readings, applications: applications, uptime: uptime,
                                             coreCount: ProcessInfo.processInfo.activeProcessorCount)
            var interfaceCount = 0
            var networkValid: Int32 = 0
            let interfaces = rb_network_samples(&interfaceCount, &networkValid)
            var counters: [NetworkCounter] = []
            if let interfaces = interfaces {
                for index in 0..<interfaceCount {
                    let interface = interfaces[index]
                    let name = withUnsafeBytes(of: interface.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    counters.append(NetworkCounter(id: "\(interface.index):\(name)", name: name,
                                                   received: interface.received_bytes, sent: interface.sent_bytes))
                }
                rb_free_network_samples(interfaces)
            }
            let result = SampleResult(raw: system, cpu: self.cpu.sample(system), apps: apps,
                                      timestamp: Date(), processReadCount: count,
                                      network: self.network.sample(networkValid == 1 ? counters : nil, uptime: uptime),
                                      battery: BatteryStatus(raw: rb_battery_sample()))
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class MonitorStore: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var usedMemory: UInt64 = 0
    @Published private(set) var totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var wiredMemory: UInt64 = 0
    @Published private(set) var compressedMemory: UInt64 = 0
    @Published private(set) var cachedMemory: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var pressure = MemoryPressure.unknown
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var applications: [AppUsage] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var memoryAvailable = false
    @Published private(set) var network = NetworkStatus.loading
    @Published private(set) var battery = BatteryStatus.loading
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var message: String?
    @Published var operationPID: Int32?
    @Published var menuStyle: MenuStyle {
        didSet { defaults.set(menuStyle.rawValue, forKey: "menuStyle"); onStatusChange?() }
    }
    @Published var interval: Double {
        didSet { defaults.set(interval, forKey: "interval"); if started { configureTimer() } }
    }
    @Published private(set) var cpuAlerts: Bool
    @Published private(set) var memoryAlerts: Bool

    var onStatusChange: (() -> Void)?
    var onOpenRequested: (() -> Void)?
    var memoryPercent: Double { totalMemory > 0 ? Double(usedMemory) / Double(totalMemory) * 100 : 0 }
    var needsAttention: Bool { (cpu ?? 0) > 85 || pressure == .critical || pressure == .warning }
    var statusText: String { lastUpdated == nil ? "正在采样" : needsAttention ? "需要关注" : "运行正常" }
    var readableProcessCount = 0

    private let defaults: UserDefaults
    private let sampler = SystemSampler()
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var inFlight = false
    private var sleeping = false
    private var cpuGate = SustainedAlertGate()
    private var memoryGate = SustainedAlertGate()
    private var iconCache: [String: NSImage] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuStyle = MenuStyle(rawValue: defaults.string(forKey: "menuStyle") ?? "") ?? .both
        let savedInterval = defaults.double(forKey: "interval")
        interval = [1.0, 2.0, 5.0].contains(savedInterval) ? savedInterval : 2
        cpuAlerts = defaults.bool(forKey: "cpuAlerts")
        memoryAlerts = defaults.bool(forKey: "memoryAlerts")
    }

    func start() {
        guard !started else { return }
        started = true
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let flags = source?.data else { return }
            if flags.contains(.critical) { self.pressure = .critical }
            else if flags.contains(.warning) { self.pressure = .warning }
            else if flags.contains(.normal) { self.pressure = .normal }
            self.onStatusChange?()
        }
        source.resume()
        pressureSource = source
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.cpuGate.resetEpisode()
            self?.memoryGate.resetEpisode()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.cpuGate.resetEpisode()
            self?.memoryGate.resetEpisode()
            self?.sample()
        })
        refreshNotificationStatus()
        configureTimer()
        sample()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = interval * 0.15
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func sample() {
        guard !inFlight, !sleeping, started else { return }
        inFlight = true
        let identities = NSWorkspace.shared.runningApplications.compactMap { app -> ApplicationIdentity? in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url = app.bundleURL else { return nil }
            return ApplicationIdentity(pid: app.processIdentifier, bundlePath: url.path,
                                       name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                       bundleID: app.bundleIdentifier ?? "", launched: app.launchDate)
        }
        sampler.sample(applications: identities) { [weak self] result in
            guard let self = self else { return }
            self.inFlight = false
            guard self.started, !self.sleeping else { return }
            if let last = self.lastUpdated, result.timestamp.timeIntervalSince(last) > max(10, self.interval * 3) {
                self.cpuGate.resetEpisode()
                self.memoryGate.resetEpisode()
            }
            self.cpu = result.cpu
            self.network = result.network
            self.battery = result.battery
            self.memoryAvailable = result.raw.memory_valid == 1
            self.totalMemory = result.raw.total_memory > 0 ? result.raw.total_memory : ProcessInfo.processInfo.physicalMemory
            self.usedMemory = result.raw.used_memory
            self.wiredMemory = result.raw.wired_memory
            self.compressedMemory = result.raw.compressed_memory
            self.cachedMemory = result.raw.cached_memory
            self.swapUsed = result.raw.swap_used
            let pressure = MemoryPressure(level: result.raw.memory_pressure)
            if pressure != .unknown { self.pressure = pressure }
            self.applications = result.apps
            self.readableProcessCount = result.processReadCount
            self.lastUpdated = result.timestamp
            if self.memoryAvailable {
                self.history.append(HistoryPoint(date: result.timestamp, cpu: result.cpu, memory: self.memoryPercent))
            }
            self.history.removeAll { result.timestamp.timeIntervalSince($0.date) > 300 }
            self.evaluateAlerts(now: result.timestamp)
            self.onStatusChange?()
        }
    }

    func sortedApplications(by sort: ResourceSort) -> [AppUsage] {
        applications.sorted {
            let left = sort == .cpu ? $0.cpu ?? -1 : Double($0.memory)
            let right = sort == .cpu ? $1.cpu ?? -1 : Double($1.memory)
            return left == right ? $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending : left > right
        }
    }

    func icon(for app: ApplicationIdentity) -> NSImage {
        if let icon = iconCache[app.bundlePath] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.bundlePath)
        if iconCache.count > 150 { iconCache.removeAll() }
        iconCache[app.bundlePath] = icon
        return icon
    }

    func terminate(_ identity: ApplicationIdentity, force: Bool) {
        guard !identity.protected else { message = "为保证桌面正常运行，此应用不能在这里结束。"; return }
        guard let running = NSRunningApplication(processIdentifier: identity.pid), !running.isTerminated,
              running.bundleURL?.path == identity.bundlePath, running.launchDate == identity.launched else {
            message = "该应用已经退出或重新启动，请刷新后重试。"; return
        }
        guard running.isFinishedLaunching else { message = "该应用仍在启动，请稍后重试。"; return }
        let accepted = force ? running.forceTerminate() : running.terminate()
        guard accepted else {
            message = force ? "系统未允许结束此应用。可以打开活动监视器进一步查看。" : "无法请求退出。应用可能没有响应，可在详情中选择强制结束。"
            return
        }
        operationPID = identity.pid
        message = force ? "已请求强制结束 \(identity.name)。" : "已请求 \(identity.name) 退出，请留意它的保存提示。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self else { return }
            self.operationPID = nil
            if running.isTerminated {
                self.message = "\(identity.name) 已退出。"
            } else {
                self.message = "\(identity.name) 仍在运行。请先处理保存提示；若无响应，可选择强制结束。"
            }
        }
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if let error = error { DispatchQueue.main.async { self?.message = "无法打开活动监视器：\(error.localizedDescription)" } }
        }
    }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { message = "无法更新登录启动：\(error.localizedDescription)" }
        refreshLoginStatus()
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.notificationStatus = settings.authorizationStatus }
        }
    }

    func setAlerts(cpu: Bool, enabled: Bool) {
        if !enabled { saveAlertSetting(cpu: cpu, enabled: false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshNotificationStatus()
                if granted { self.saveAlertSetting(cpu: cpu, enabled: true) }
                else { self.message = error.map { "通知权限请求失败：\($0.localizedDescription)" } ?? "系统通知尚未允许，请在系统设置 → 通知 → 资源看板中开启。" }
            }
        }
    }

    private func saveAlertSetting(cpu: Bool, enabled: Bool) {
        if cpu { cpuAlerts = enabled; cpuGate.resetEpisode(); defaults.set(enabled, forKey: "cpuAlerts") }
        else { memoryAlerts = enabled; memoryGate.resetEpisode(); defaults.set(enabled, forKey: "memoryAlerts") }
    }

    private func evaluateAlerts(now: Date) {
        if cpuGate.update(active: cpu.map { $0 > 85 } ?? false, enabled: cpuAlerts, now: now, duration: 60) {
            let top = sortedApplications(by: .cpu).first.map { "当前占用最高：\($0.identity.name)。" } ?? "可打开看板查看应用排行。"
            notify(id: "cpu", title: "CPU 持续高占用", body: "全机占用超过 85%，持续至少 1 分钟。\(top)")
        }
        if memoryGate.update(active: pressure == .critical, enabled: memoryAlerts, now: now, duration: 30) {
            notify(id: "memory", title: "内存压力严重", body: "系统内存压力已持续严重 30 秒。已用 \(Format.bytes(usedMemory))，可检查高占用应用。")
        }
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "resourceboard.\(id)", content: content, trigger: nil)) { [weak self] error in
            if let error = error { DispatchQueue.main.async { self?.message = "提醒发送失败：\(error.localizedDescription)" } }
        }
    }
}
