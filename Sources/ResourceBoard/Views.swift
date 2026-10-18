import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

enum Screen { case overview, settings, application(ApplicationIdentity), memory, network, battery }

struct BoardView: View {
    static var panelHeight: CGFloat { min(700, max(500, (NSScreen.main?.visibleFrame.height ?? 800) - 40)) }
    @ObservedObject var store: MonitorStore
    @State private var screen: Screen = .overview
    @State private var sort: ResourceSort = .cpu
    @State private var expanded = false
    @State private var pending: ApplicationIdentity?
    @State private var force = false

    init(store: MonitorStore, initialScreen: Screen = .overview) {
        self.store = store
        _screen = State(initialValue: initialScreen)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch screen {
                case .overview: overview
                case .settings: settings
                case .application(let app): applicationDetail(app)
                case .memory: memoryDetail
                case .network: networkDetail
                case .battery: batteryDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let message = store.message {
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
                .padding(10).background(Color.primary.opacity(0.045)).cornerRadius(7).padding(.horizontal, 16).padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: Self.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(force ? "强制结束 \(pending?.name ?? "应用")？" : "退出 \(pending?.name ?? "应用")？",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("取消", role: .cancel) { pending = nil }
            Button(force ? "强制结束" : "退出应用", role: force ? .destructive : nil) {
                if let app = pending { store.terminate(app, force: force) }
                pending = nil
            }
        } message: {
            Text(force ? "应用将立即终止，未保存的更改可能丢失。" : "将请求应用正常退出。请留意应用的保存提示。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            switch screen {
            case .overview:
                Image(systemName: "waveform.path.ecg").foregroundColor(.accentColor)
                Text("资源看板").font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle().fill(store.needsAttention ? Color.orange : store.lastUpdated == nil ? Color.secondary : Color.green).frame(width: 6, height: 6)
                Text(store.statusText).font(.system(size: 11)).foregroundColor(.secondary)
            default:
                Button { screen = .overview } label: { Label("返回", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text(screenTitle).font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 45, height: 1)
            }
        }
        .padding(.horizontal, 18).frame(height: 48)
    }

    private var screenTitle: String {
        switch screen {
        case .settings: return "设置"
        case .application: return "应用详情"
        case .memory: return "内存明细"
        case .network: return "网络监控"
        case .battery: return "电池监控"
        default: return "资源看板"
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            if store.needsAttention {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.pressure == .critical ? "系统内存压力严重" : store.pressure == .warning ? "系统内存压力偏高" : "CPU 当前占用较高").font(.system(size: 12, weight: .medium))
                        Text("可在下方查看占用较高的应用。").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10).background(Color.orange.opacity(0.10)).cornerRadius(8).padding(.bottom, 10)
            }
            HStack(alignment: .top, spacing: 10) {
                metric(memory: false)
                metric(memory: true)
            }
            HStack(alignment: .top, spacing: 10) {
                networkCard
                batteryCard
            }.padding(.top, 10)
            HStack {
                Text("占用排行").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("排序", selection: $sort) {
                    ForEach(ResourceSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 122)
            }.padding(.top, 17).padding(.bottom, 9)
            HStack {
                Text("应用")
                Spacer()
                Text("CPU").frame(width: 49, alignment: .trailing)
                Text("内存").frame(width: 66, alignment: .trailing)
            }.font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 6).padding(.trailing, 14).padding(.bottom, 5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    let apps = store.sortedApplications(by: sort)
                    ForEach(expanded ? apps : Array(apps.prefix(3))) { app in applicationRow(app) }
                    if apps.isEmpty {
                        Text(store.lastUpdated == nil ? "正在读取应用占用…" : "暂无可读取的前台应用。可打开活动监视器查看所有进程。")
                            .font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 28)
                    }
                }.padding(.trailing, 14)
            }
            .frame(maxHeight: .infinity)
            if store.applications.count > 3 {
                Button(expanded ? "收起列表" : "显示全部 \(store.applications.count) 个应用") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.accentColor).padding(.top, 8)
            }
            HStack {
                Text("CPU 按全机 0–100% 计 · 同应用辅助进程已合并")
                Spacer(minLength: 0)
            }.font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var networkCard: some View {
        Button { screen = .network } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("网速", systemImage: "network").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary)
                }
                HStack {
                    Image(systemName: "arrow.down").foregroundColor(.blue)
                    Text(Format.rate(store.network.download)).monospacedDigit()
                    Spacer(minLength: 0)
                }.font(.system(size: 14, weight: .medium))
                HStack {
                    Image(systemName: "arrow.up").foregroundColor(.purple)
                    Text(Format.rate(store.network.upload)).monospacedDigit()
                    Spacer(minLength: 0)
                }.font(.system(size: 12))
                Text(store.network.description).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 119)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("网络监控，下载 \(Format.rate(store.network.download))，上传 \(Format.rate(store.network.upload))")
    }

    private var batteryCard: some View {
        Button { screen = .battery } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("电池", systemImage: store.battery.symbol).font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary)
                }
                Text(store.battery.percent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundColor(store.battery.percent.map { $0 <= 20 && !store.battery.onAC } == true ? .red : .primary)
                Text(store.battery.state).font(.system(size: 11)).foregroundColor(store.battery.charging ? .green : .secondary).lineLimit(1)
                Text(store.battery.timeDescription).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.9)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 119)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("电池监控，\(store.battery.state)")
    }

    private var networkDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            fact("实时下载", value: Format.rate(store.network.download))
            fact("实时上传", value: Format.rate(store.network.upload))
            fact("活动接口", value: store.network.description)
            fact("采样频率", value: "\(Int(store.interval)) 秒")
            Text("统计活动 Wi-Fi／有线网络接口的实际收发字节，包括局域网流量。排除回环、VPN 隧道及虚拟桥接接口，避免重复计数。")
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 16)
            Text("采用十进制 B/s、KB/s、MB/s（字节／秒），不是运营商标注的 Mbps。刚启动、切换接口或唤醒时需要重新积累一个采样周期。")
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 10)
            Spacer()
        }.padding(.horizontal, 20).padding(.top, 10)
    }

    private var batteryDetail: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            fact("当前电量", value: store.battery.percent.map { String(format: "%.0f%%", $0) } ?? "—")
            fact("电池状态", value: store.battery.state)
            if store.battery.available && store.battery.present {
                fact("供电来源", value: store.battery.onAC ? "外接电源" : "内置电池")
                fact("低电量模式", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "已开启" : "未开启")
              Group {
                Text("电池健康").font(.system(size: 13, weight: .semibold)).padding(.top, 20).padding(.bottom, 2)
                HStack {
                    Text("健康状态").foregroundColor(.secondary)
                    Spacer()
                    Text(store.battery.healthDescription).foregroundColor(Color(nsColor: store.battery.healthColor))
                }.font(.system(size: 12)).padding(.vertical, 12).overlay(alignment: .bottom) { Divider().opacity(0.6) }
                fact(store.battery.capacityEstimated ? "最大容量（估算）" : "最大容量",
                     value: store.battery.maximumCapacity.map { String(format: "%.0f%%", $0) } ?? "系统未提供")
                fact("循环次数", value: store.battery.cycleCount.map { "\($0) 次" } ?? "系统未提供")
                fact("满充容量", value: store.battery.fullCapacity.map { "\($0) mAh" } ?? "系统未提供")
                fact("设计容量", value: store.battery.designCapacity.map { "\($0) mAh" } ?? "系统未提供")
              }
                Text(store.battery.capacityEstimated
                     ? "最大容量是满充容量相对设计容量的估算比例，与当前剩余电量不同；可能与系统设置的显示略有差异。健康状态直接采用系统报告。"
                     : "最大容量表示电池相对新电池的储电能力，与当前剩余电量不同。健康状态采用系统报告；系统未提供的项目不会推算。")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                Text(store.battery.timeDescription).font(.system(size: 12)).padding(.top, 18)
                Text("剩余时间由 macOS 提供，会随当前负载变化。系统未提供估算时不显示推算数值。接电但未充电可能来自充电优化或电池保护。")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 12)
            } else {
                Text(store.battery.available ? "此 Mac 未检测到内置电池，CPU、内存和网速监控仍可正常使用。" : "暂时无法从系统读取电池信息。")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 18)
            }
          }.padding(.leading, 20).padding(.trailing, 26).padding(.top, 10).padding(.bottom, 18)
        }
    }

    private func metric(memory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(memory ? "内存" : "CPU", systemImage: memory ? "memorychip" : "cpu")
                .font(.system(size: 12)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(memory ? (store.memoryAvailable ? String(format: "%.1f", Double(store.usedMemory) / 1_073_741_824) : "—") : store.cpu.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(memory ? "/ \(String(format: "%.0f", Double(store.totalMemory) / 1_073_741_824)) GB" : "%")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }.lineLimit(1).minimumScaleFactor(0.8)
            TrendChart(points: store.history, memory: memory).frame(height: 39).padding(.top, 4)
            HStack {
                Text("5 分钟")
                Spacer(minLength: 0)
                Text("现在")
            }.font(.system(size: 9)).foregroundColor(.secondary)
            if memory {
                HStack(spacing: 3) {
                    Text("压力")
                    Text(store.pressure.rawValue).foregroundColor(Color(nsColor: store.pressure.color))
                    Spacer(minLength: 0)
                    Button { screen = .memory } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).accessibilityLabel("查看内存明细")
                }.font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 5)
            } else {
                Text("全机 · \(ProcessInfo.processInfo.activeProcessorCount) 个逻辑核心")
                    .font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 5)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func applicationRow(_ app: AppUsage) -> some View {
        Button { screen = .application(app.identity) } label: {
            HStack(spacing: 8) {
                Image(nsImage: store.icon(for: app.identity)).resizable().frame(width: 26, height: 26)
                Text(app.identity.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(Format.percent(app.cpu)).frame(width: 49, alignment: .trailing)
                Text(Format.bytes(app.memory)).frame(width: 66, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit().padding(.horizontal, 6).frame(height: 45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看 \(app.identity.name) 详情")
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func applicationDetail(_ identity: ApplicationIdentity) -> some View {
        let app = store.applications.first { $0.identity == identity }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: store.icon(for: identity)).resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Text(app == nil ? "已退出或无法读取" : "正在运行 · \(app!.processCount) 个进程").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }.padding(.bottom, 20)
            fact("CPU 占用 · 全机口径", value: Format.percent(app?.cpu))
            fact("内存占用 · 合并估算", value: app.map { Format.bytes($0.memory) } ?? "—")
            fact("主进程 PID", value: String(identity.pid))
            if let launched = identity.launched { fact("启动时间", value: launched.formatted(date: .omitted, time: .shortened)) }
            Text(identity.bundlePath).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            Spacer()
            if identity.protected {
                Text("桌面系统组件受保护，请在活动监视器中查看。").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Text("优先正常退出，保留应用保存更改的机会。无响应时再强制结束。").font(.system(size: 11)).foregroundColor(.secondary).padding(.bottom, 14)
                HStack {
                    Button { force = false; pending = identity } label: { Text("退出应用").foregroundColor(.primary) }
                    Spacer()
                    Button(role: .destructive) { force = true; pending = identity } label: { Text("强制结束…").foregroundColor(.red) }
                }.disabled(app == nil || store.operationPID == identity.pid)
            }
        }.padding(20)
    }

    private var memoryDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            fact("物理内存", value: Format.bytes(store.totalMemory))
            fact("已用内存", value: store.memoryAvailable ? Format.bytes(store.usedMemory) : "—")
            fact("系统内存压力", value: store.pressure.rawValue)
            fact("联动内存（Wired）", value: Format.bytes(store.wiredMemory))
            fact("压缩内存", value: Format.bytes(store.compressedMemory))
            fact("可回收缓存", value: Format.bytes(store.cachedMemory))
            fact("已用交换空间", value: Format.bytes(store.swapUsed))
            Text("已用内存依据内核页统计估算，不包含可回收的文件缓存和可清除页。应用排行使用各进程的物理内存占用估算，与系统总量口径不同。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 16)
            Text("判断内存是否紧张，优先查看系统内存压力。").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 8)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 10)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingRow("登录时启动", detail: "运行后仅显示在顶部菜单栏") {
                    Toggle("登录时启动", isOn: Binding(get: { store.loginStatus == .enabled || store.loginStatus == .requiresApproval }, set: { store.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if store.loginStatus == .requiresApproval {
                    Button("前往系统设置允许登录启动") { store.openLoginSettings() }.font(.system(size: 11)).padding(.vertical, 6)
                }
                settingRow("菜单栏显示") {
                    Picker("菜单栏显示", selection: $store.menuStyle) {
                        ForEach(MenuStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 128)
                }
                settingRow("刷新频率") {
                    Picker("刷新频率", selection: $store.interval) {
                        Text("1 秒").tag(1.0); Text("2 秒").tag(2.0); Text("5 秒").tag(5.0)
                    }.labelsHidden().frame(width: 85)
                }
                settingRow("CPU 高占用提醒", detail: "超过 85%，持续 60 秒") {
                    Toggle("CPU 高占用提醒", isOn: Binding(get: { store.cpuAlerts }, set: { store.setAlerts(cpu: true, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                settingRow("内存压力提醒", detail: "系统压力严重，持续 30 秒") {
                    Toggle("内存压力提醒", isOn: Binding(get: { store.memoryAlerts }, set: { store.setAlerts(cpu: false, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                settingRow("同类提醒间隔", detail: "持续异常只提醒一次，恢复后重新判断") { Text("10 分钟").foregroundColor(.secondary).font(.system(size: 11)) }
                if store.notificationStatus == .denied {
                    Text("通知已被系统关闭。请在系统设置 → 通知 → 资源看板中开启。")
                        .font(.system(size: 11)).foregroundColor(.orange).padding(.top, 12)
                } else if store.notificationStatus == .notDetermined {
                    Text("开启提醒时申请系统通知权限。").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 12)
                }
                Text("资源看板 1.2.1\n所有数据在本机采集和处理，无网络请求。")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 18)
            }.padding(.horizontal, 20).padding(.bottom, 18)
        }.onAppear { store.refreshLoginStatus(); store.refreshNotificationStatus() }
    }

    private func settingRow<T: View>(_ name: String, detail: String? = nil, @ViewBuilder control: () -> T) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12))
                if let detail = detail { Text(detail).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func fact(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundColor(.secondary); Spacer(); Text(value).monospacedDigit() }
            .font(.system(size: 12)).padding(.vertical, 12).overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { store.openActivityMonitor() } label: { Label("活动监视器", systemImage: "arrow.up.forward.app") }.buttonStyle(.plain)
            Spacer()
            Button { screen = .settings } label: { Label("设置", systemImage: "slider.horizontal.3").foregroundColor(.primary) }
            Menu {
                Button("退出资源看板") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).help("更多")
        }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 43)
    }
}

struct TrendChart: View {
    let points: [HistoryPoint]
    let memory: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let end = points.last?.date ?? Date()
            ZStack {
                Path { path in
                    for ratio in [0.2, 0.6] {
                        path.move(to: CGPoint(x: 0, y: height * ratio))
                        path.addLine(to: CGPoint(x: width, y: height * ratio))
                    }
                }.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                Path { path in
                    var last: Date?
                    for point in points {
                        guard let value = memory ? point.memory : point.cpu else { last = nil; continue }
                        let x = width * max(0, 1 - end.timeIntervalSince(point.date) / 300)
                        let y = height * (1 - min(100, max(0, value)) / 100)
                        let coordinate = CGPoint(x: x, y: y)
                        if let previous = last, point.date.timeIntervalSince(previous) <= 16 { path.addLine(to: coordinate) }
                        else { path.move(to: coordinate) }
                        last = point.date
                    }
                }.stroke(memory ? Color.purple : Color.blue, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                if points.count < 2 { Text("采样积累中").font(.system(size: 9)).foregroundColor(.secondary) }
            }
        }
        .accessibilityLabel(memory ? "最近五分钟内存占用趋势" : "最近五分钟 CPU 占用趋势")
    }
}
