import AppKit

final class TerminationTestDelegate: NSObject, NSApplicationDelegate {
    private var children: [Process] = []
    private let store = MonitorStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.runTests() }
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    private func require(_ condition: Bool, _ label: String) {
        if !condition {
            // Cleanup is limited to fixture processes launched by this test instance.
            children.filter(\.isRunning).forEach { $0.terminate() }
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }

    private func launch(refuse: Bool) -> (Process, ApplicationIdentity) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = refuse ? ["--refuse"] : []
        do { try process.run() } catch { require(false, "launch owned fixture: \(error)") }
        children.append(process)
        require(wait { NSRunningApplication(processIdentifier: process.processIdentifier)?.bundleIdentifier == "local.resourceboard.fixture" }, "fixture registers with Launch Services")
        require(wait { NSRunningApplication(processIdentifier: process.processIdentifier)?.isFinishedLaunching == true }, "fixture finishes launching before management")
        let app = NSRunningApplication(processIdentifier: process.processIdentifier)!
        let identity = ApplicationIdentity(pid: process.processIdentifier, bundlePath: app.bundleURL!.path,
                                           name: "ResourceBoard Test Fixture", bundleID: app.bundleIdentifier!, launched: app.launchDate)
        return (process, identity)
    }

    private func runTests() {
        let (normal, normalID) = launch(refuse: false)
        store.terminate(normalID, force: false)
        print("Normal exit request: \(store.message ?? "no result")")
        require(wait { !normal.isRunning }, "normal exit terminates only the owned fixture")

        let (stubborn, stubbornID) = launch(refuse: true)
        store.terminate(stubbornID, force: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        require(stubborn.isRunning, "normal exit respects an application's refusal / save flow")
        store.terminate(stubbornID, force: true)
        require(wait { !stubborn.isRunning }, "force exit terminates the owned unresponsive fixture")

        store.terminate(stubbornID, force: true)
        require(store.message?.contains("已经退出") == true, "stale application identity is rejected")
        let selfID = ApplicationIdentity(pid: getpid(), bundlePath: Bundle.main.bundlePath, name: "Tests", bundleID: "local.resourceboard.integration", launched: nil)
        store.terminate(selfID, force: true)
        require(store.message?.contains("不能") == true, "management refuses to terminate itself")
        print("Termination integration checks passed. Only two dedicated test fixtures were terminated.")
        NSApp.terminate(nil)
    }
}

@main
struct TerminationTests {
    static func main() {
        let app = NSApplication.shared
        let delegate = TerminationTestDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
