import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CommandLine.arguments.contains("--refuse") ? .terminateCancel : .terminateNow
    }
}

@main
struct TerminationFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
