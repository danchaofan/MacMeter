import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = MonitorStore()
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var hosting: NSHostingController<BoardView>!
    private var menu: NSMenu!
    private var activationObserver: NSObjectProtocol?
    private var smokeTimer: Timer?
    private var smokeDirectory: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1 else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if smokeDirectory == nil, let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [])
                NSApp.terminate(nil)
                return
            }
        }
        UNUserNotificationCenter.current().delegate = self
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.setAccessibilityLabel("资源看板")
        }
        hosting = NSHostingController(rootView: BoardView(store: store))
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: BoardView.panelHeight)
        popover.contentViewController = hosting
        menu = NSMenu()
        menu.addItem(withTitle: "打开资源看板", action: #selector(openBoard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开活动监视器", action: #selector(openActivity), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出资源看板", action: #selector(quit), keyEquivalent: "q").target = self
        store.onStatusChange = { [weak self] in self?.updateStatus() }
        store.onOpenRequested = { [weak self] in self?.openBoard() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.refreshLoginStatus()
            self?.store.refreshNotificationStatus()
        }
        updateStatus()
        store.start()
        if let directory = smokeDirectory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.openBoard() }
            let deadline = Date().addingTimeInterval(25)
            smokeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if (self.store.history.count >= 2 && self.store.network.download != nil && self.popover.isShown) || Date() >= deadline {
                    timer.invalidate()
                    self.saveSmokeTest(to: directory)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openBoard(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        smokeTimer?.invalidate()
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
        if let item = item { NSStatusBar.system.removeStatusItem(item) }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { openBoard() }
    }

    @objc func openBoard() {
        guard let button = item?.button else { return }
        if !popover.isShown {
            // A retained hosting controller also retains SwiftUI navigation @State after dismissal.
            // Start a new presentation at the overview; monitoring data stays in the shared store.
            hosting = NSHostingController(rootView: BoardView(store: store))
            popover.contentViewController = hosting
        }
        NSApp.activate(ignoringOtherApps: true)
        store.refreshNotificationStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc private func openActivity() { store.openActivityMonitor() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatus() {
        guard let button = item?.button else { return }
        let cpu = store.cpu.map { String(format: "%.0f%%", $0) } ?? "—"
        let memory = store.memoryAvailable ? String(format: "%.0f%%", store.memoryPercent) : "—"
        let symbol = store.needsAttention ? "exclamationmark.circle" : "waveform.path.ecg"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        switch store.menuStyle {
        case .both: button.title = " CPU \(cpu)  MEM \(memory)"
        case .cpu: button.title = " \(cpu)"
        case .memory: button.title = " \(memory)"
        case .network: button.title = " ↓\(Format.rate(store.network.download)) ↑\(Format.rate(store.network.upload))"
        case .battery:
            button.title = " " + (store.battery.percent.map { String(format: "%.0f%%", $0) } ?? "—")
            button.image = NSImage(systemSymbolName: store.battery.symbol, accessibilityDescription: "电池")
            button.image?.isTemplate = true
        case .icon: button.title = ""
        }
        button.toolTip = "CPU \(cpu) · 内存 \(memory) · 压力\(store.pressure.rawValue)\n下载 \(Format.rate(store.network.download)) · 上传 \(Format.rate(store.network.upload))\n电池 \(store.battery.percent.map { String(format: "%.0f%%", $0) } ?? "—") · \(store.battery.state)\n左键打开看板，右键显示菜单"
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.openBoard(); completionHandler() }
    }

    private func saveSmokeTest(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reopenedToOverview = try verifyReopening(to: directory)
            func capture(_ screen: Screen, name: String, dark: Bool = false) throws {
                let view = NSHostingView(rootView: BoardView(store: store, initialScreen: screen).environment(\.colorScheme, dark ? .dark : .light))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: BoardView.panelHeight), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 400, height: BoardView.panelHeight)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent(name + ".png"))
                    }
                }
                window.orderOut(nil)
            }
            try capture(.overview, name: "resource-board")
            try capture(.overview, name: "resource-board-dark", dark: true)
            try capture(.settings, name: "settings")
            try capture(.memory, name: "memory-details")
            try capture(.network, name: "network-details")
            try capture(.battery, name: "battery-details")
            try capture(.battery, name: "battery-details-dark", dark: true)
            if let app = store.applications.first { try capture(.application(app.identity), name: "application-details") }
            let report: [String: Any] = [
                "cpuPercent": store.cpu as Any? ?? NSNull(), "memoryUsed": store.usedMemory,
                "memoryTotal": store.totalMemory, "memoryPressure": store.pressure.rawValue,
                "memoryAvailable": store.memoryAvailable, "historySamples": store.history.count,
                "networkAvailable": store.network.available,
                "downloadBytesPerSecond": store.network.download as Any? ?? NSNull(),
                "uploadBytesPerSecond": store.network.upload as Any? ?? NSNull(),
                "networkInterfaces": store.network.interfaces,
                "batteryAvailable": store.battery.available, "batteryPresent": store.battery.present,
                "batteryPercent": store.battery.percent as Any? ?? NSNull(),
                "batteryState": store.battery.state,
                "batteryHealth": store.battery.healthDescription,
                "batteryMaximumCapacity": store.battery.maximumCapacity as Any? ?? NSNull(),
                "batteryCapacityEstimated": store.battery.capacityEstimated,
                "batteryCycles": store.battery.cycleCount as Any? ?? NSNull(),
                "batteryDesignCapacityMAh": store.battery.designCapacity as Any? ?? NSNull(),
                "batteryFullCapacityMAh": store.battery.fullCapacity as Any? ?? NSNull(),
                "readableProcesses": store.readableProcessCount, "applicationCount": store.applications.count,
                "statusItemCreated": item.button != nil, "viewWidth": hosting.view.bounds.width,
                "viewHeight": hosting.view.bounds.height,
                "popoverShown": popover.isShown,
                "reopenResetsNavigation": reopenedToOverview,
                "applications": store.applications.map { ["name": $0.identity.name, "cpu": $0.cpu as Any? ?? NSNull(), "memory": $0.memory, "processes": $0.processCount] as [String: Any] }
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("smoke-report.json"))
        } catch { fputs("Smoke test failed: \(error)\n", stderr) }
        NSApp.terminate(nil)
    }

    private func verifyReopening(to directory: URL) throws -> Bool {
        guard let button = item.button else { throw NSError(domain: "ResourceBoard.Smoke", code: 1) }
        let animations = popover.animates
        popover.animates = false
        defer { popover.animates = animations }
        popover.performClose(nil)

        // Put the real popover in the same state as navigating into the battery page.
        hosting = NSHostingController(rootView: BoardView(store: store, initialScreen: .battery))
        popover.contentViewController = hosting
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hosting.view.layoutSubtreeIfNeeded()
        let detailController = hosting!
        let samplesBefore = store.history.count

        // An outside click dismisses the same transient popover. Reopen via the production entry point.
        popover.performClose(nil)
        guard !popover.isShown else { throw NSError(domain: "ResourceBoard.Smoke", code: 2) }
        openBoard()
        hosting.view.layoutSubtreeIfNeeded()
        guard hosting !== detailController, hosting.rootView.store === store,
              store.history.count == samplesBefore, popover.isShown else {
            throw NSError(domain: "ResourceBoard.Smoke", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Reopening did not reset the presentation while retaining monitoring data."])
        }
        if let bitmap = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds) {
            hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("reopened-board.png"))
            }
        }
        return true
    }
}
