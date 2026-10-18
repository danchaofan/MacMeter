import AppKit
import Foundation
import CSystem

@main
struct MonitorTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
        print("PASS: \(label)")
    }
    static func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.001 } ?? false }

    static func main() {
        var cpu = CPUTracker()
        var raw = RBSystemSample()
        raw.cpu_valid = 1
        raw.cpu_user = 100; raw.cpu_system = 50; raw.cpu_nice = 0; raw.cpu_idle = 850
        expect(cpu.sample(raw) == nil, "first CPU sample establishes a baseline")
        raw.cpu_user += 15; raw.cpu_system += 5; raw.cpu_idle += 80
        expect(near(cpu.sample(raw), 20), "system CPU uses interval deltas and a 0–100 scale")
        expect(cpu.sample(raw) == nil, "unchanged CPU ticks do not fabricate zero utilization")
        var wrapTracker = CPUTracker()
        raw.cpu_user = UInt64(UInt32.max) - 5; raw.cpu_system = 10; raw.cpu_idle = 20
        _ = wrapTracker.sample(raw)
        raw.cpu_user = 4; raw.cpu_idle = 30
        expect(near(wrapTracker.sample(raw), 50), "CPU tick rollover is handled")
        raw.cpu_valid = 0
        expect(cpu.sample(raw) == nil, "failed system samples are unavailable")

        let a = ApplicationIdentity(pid: 10, bundlePath: "/Applications/A.app", name: "A", bundleID: "test.a", launched: nil)
        let b = ApplicationIdentity(pid: 20, bundlePath: "/Applications/A.app.extra/B.app", name: "B", bundleID: "test.b", launched: nil)
        func process(_ pid: Int32, _ parent: Int32, _ path: String, _ nanos: UInt64, _ memory: UInt64 = 100, start: UInt64 = 1) -> ProcessReading {
            ProcessReading(pid: pid, parent: parent, start: start, cpu: nanos, memory: memory, path: path)
        }
        let tracker = ProcessTracker()
        let first = [process(10, 1, "/Applications/A.app/Contents/MacOS/A", 0),
                     process(11, 1, "/Applications/A.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", 0),
                     process(12, 10, "/usr/bin/something", 0),
                     process(20, 1, "/Applications/A.app.extra/B.app/Contents/MacOS/B", 0),
                     process(40, 41, "/usr/bin/cycle", 0), process(41, 40, "/usr/bin/cycle", 0)]
        let baseline = tracker.sample(first, applications: [a, b], uptime: 10, coreCount: 4)
        expect(baseline.first { $0.id == 10 }?.processCount == 3, "nested and reparented helpers merge with their owning app")
        expect(baseline.first { $0.id == 20 }?.processCount == 1, "bundle path prefixes require a directory boundary")
        expect(baseline.allSatisfy { $0.cpu == nil }, "first app CPU sample is unavailable")
        let second = [process(10, 1, "/Applications/A.app/Contents/MacOS/A", 1_000_000_000),
                      process(11, 1, "/Applications/A.app/Contents/Helper", 1_000_000_000),
                      process(12, 10, "/usr/bin/something", 0),
                      process(20, 1, "/Applications/A.app.extra/B.app/Contents/MacOS/B", 2_000_000_000),
                      process(21, 20, "/usr/bin/new", 100_000_000_000)]
        let next = tracker.sample(second, applications: [a, b], uptime: 12, coreCount: 4)
        expect(near(next.first { $0.id == 10 }?.cpu, 25), "application CPU normalizes across logical cores")
        expect(near(next.first { $0.id == 20 }?.cpu, 25), "new process CPU lifetime is not mistaken for an interval")
        expect(next.first { $0.id == 10 }?.memory == 300, "application footprints aggregate once per process")
        let reused = tracker.sample([process(10, 1, a.bundlePath + "/main", 900_000_000_000, start: 2)], applications: [a], uptime: 14, coreCount: 4)
        expect(reused.first?.cpu == nil, "reused PIDs establish a fresh baseline")
        expect(tracker.sample([], applications: [a], uptime: 16, coreCount: 4).isEmpty, "terminated applications leave the list")

        var gate = SustainedAlertGate()
        let start = Date(timeIntervalSince1970: 1_000)
        expect(!gate.update(active: true, enabled: true, now: start, duration: 60), "alerts wait for a sustained condition")
        expect(!gate.update(active: true, enabled: true, now: start.addingTimeInterval(59), duration: 60), "short CPU spikes do not notify")
        expect(gate.update(active: true, enabled: true, now: start.addingTimeInterval(60), duration: 60), "sustained CPU conditions notify")
        expect(!gate.update(active: true, enabled: true, now: start.addingTimeInterval(900), duration: 60), "one notification per continuous episode")
        _ = gate.update(active: false, enabled: true, now: start.addingTimeInterval(901), duration: 60)
        _ = gate.update(active: true, enabled: true, now: start.addingTimeInterval(902), duration: 60)
        expect(gate.update(active: true, enabled: true, now: start.addingTimeInterval(962), duration: 60), "recovered conditions can notify in a new episode")
        _ = gate.update(active: false, enabled: true, now: start.addingTimeInterval(963), duration: 60)
        _ = gate.update(active: true, enabled: true, now: start.addingTimeInterval(964), duration: 60)
        expect(!gate.update(active: true, enabled: true, now: start.addingTimeInterval(1024), duration: 60), "repeat episodes respect the ten-minute cooldown")
        expect(!gate.update(active: true, enabled: false, now: start.addingTimeInterval(2000), duration: 60), "disabled alerts stay quiet")
        var sleepGate = SustainedAlertGate()
        _ = sleepGate.update(active: true, enabled: true, now: start, duration: 60)
        sleepGate.resetEpisode()
        expect(!sleepGate.update(active: true, enabled: true, now: start.addingTimeInterval(100), duration: 60), "wake resets elapsed alert time")

        let system = rb_system_sample()
        expect(system.cpu_valid == 1, "real kernel CPU counters are readable")
        expect(system.memory_valid == 1 && system.total_memory > 0, "real kernel memory counters are readable")
        expect(system.used_memory > 0 && system.used_memory <= system.total_memory, "real used memory stays within installed memory")
        var count = 0
        if let pointer = rb_process_samples(&count) {
            let entries = Array(UnsafeBufferPointer(start: pointer, count: count))
            expect(count > 0, "real process snapshot is populated")
            expect(entries.contains { $0.pid == getpid() && $0.physical_bytes > 0 }, "process footprints include the current process")
            rb_free_process_samples(pointer)
        } else { expect(false, "process snapshot allocation") }
        let own = ApplicationIdentity(pid: getpid(), bundlePath: "/tmp/Test.app", name: "self", bundleID: "test", launched: nil)
        let finder = ApplicationIdentity(pid: 99999, bundlePath: "/System/Library/CoreServices/Finder.app", name: "Finder", bundleID: "com.apple.finder", launched: nil)
        expect(own.protected && finder.protected, "self and desktop components cannot be terminated")

        var network = NetworkTracker()
        func counter(_ id: String = "4:en0", received: UInt64, sent: UInt64) -> NetworkCounter {
            NetworkCounter(id: id, name: id.components(separatedBy: ":").last!, received: received, sent: sent)
        }
        expect(network.sample([counter(received: 5_000_000_000, sent: 8_000_000_000)], uptime: 10).download == nil, "network starts with a baseline, not lifetime bytes")
        let speed = network.sample([counter(received: 5_002_000_000, sent: 8_000_500_000)], uptime: 12)
        expect(near(speed.download, 1_000_000) && near(speed.upload, 250_000), "64-bit network byte deltas yield correct rates in both directions")
        let reset = network.sample([counter(received: 100, sent: 100)], uptime: 14)
        expect(reset.download == 0 && reset.upload == 0, "reset interface counters never produce a negative rate or spike")
        let changed = network.sample([counter("8:en1", received: 900_000_000, sent: 500_000_000)], uptime: 16)
        expect(changed.download == 0 && changed.interfaces == ["en1"], "new network interfaces do not leak lifetime totals into rates")
        let disconnected = network.sample([], uptime: 18)
        expect(disconnected.download == 0 && disconnected.interfaces.isEmpty && disconnected.available, "disconnect is distinct from a failed sample")
        expect(!network.sample(nil, uptime: 20).available, "failed network reads are unavailable")
        expect(network.sample([counter(received: 1_000, sent: 1_000)], uptime: 22).download == nil, "network recovery requires a fresh baseline")
        expect(network.sample([counter(received: 9_000, sent: 9_000)], uptime: 50).download == nil, "wake and long sampling gaps rebaseline network rates")
        var multiple = NetworkTracker()
        _ = multiple.sample([counter(received: 0, sent: 0), counter("8:en1", received: 0, sent: 0)], uptime: 1)
        let combined = multiple.sample([counter(received: 100, sent: 200), counter("8:en1", received: 300, sent: 400)], uptime: 3)
        expect(near(combined.download, 200) && near(combined.upload, 300), "simultaneous physical interfaces aggregate once each")
        expect(Format.rate(999) == "999 B/s" && Format.rate(1_000) == "1.0 KB/s" && Format.rate(1_000_000) == "1.0 MB/s", "network units switch at documented decimal boundaries")
        expect(Format.rate(nil) == "—" && Format.rate(.infinity) == "—", "unavailable or invalid rates are never rendered as real values")

        var battery = RBBatterySample()
        battery.available = 1
        expect(BatteryStatus(raw: battery).state == "无内置电池" && BatteryStatus(raw: battery).percent == nil, "desktop Macs show no internal battery")
        battery.present = 1; battery.current_capacity = 40; battery.max_capacity = 80
        battery.minutes_to_empty = 125
        let discharging = BatteryStatus(raw: battery)
        expect(near(discharging.percent, 50) && discharging.state == "电池供电", "battery percentage uses current / maximum capacity")
        expect(discharging.minutesRemaining == 125 && discharging.timeDescription.contains("2 小时 5 分"), "remaining battery time uses the system estimate")
        battery.on_ac = 1; battery.charging = 1; battery.minutes_to_full = 42
        let charging = BatteryStatus(raw: battery)
        expect(charging.state == "正在充电" && charging.minutesRemaining == 42 && charging.timeDescription.contains("充满"), "charging displays time to full rather than time to empty")
        battery.charging = 0
        expect(BatteryStatus(raw: battery).minutesRemaining == nil && BatteryStatus(raw: battery).state.contains("未充电"), "external power without charging does not show a discharge estimate")
        battery.charged = 1; battery.current_capacity = 90
        expect(BatteryStatus(raw: battery).percent == 100 && BatteryStatus(raw: battery).state == "已充满", "full-charge state and outlying capacity are bounded")
        battery.charged = 0; battery.on_ac = 0; battery.minutes_to_empty = -1
        expect(BatteryStatus(raw: battery).minutesRemaining == nil, "unknown battery time is not fabricated")
        battery.max_capacity = 0
        expect(BatteryStatus(raw: battery).percent == nil, "invalid battery capacity never divides by zero")
        battery.available = 0
        expect(BatteryStatus(raw: battery).state == "暂时无法读取", "unavailable battery information differs from no battery")

        var health = RBBatterySample()
        health.available = 1; health.present = 1
        // Synthetic, rounded fixtures; never record a developer's actual battery telemetry here.
        health.health_state = 1; health.cycle_count = 200
        health.design_capacity_mah = 8000; health.full_capacity_mah = 6400
        health.capacity_source = 2; health.maximum_capacity_percent = 80
        health.current_capacity = 60; health.max_capacity = 100
        let healthy = BatteryStatus(raw: health)
        expect(healthy.healthDescription == "正常" && healthy.cycleCount == 200, "battery health state and cycle count use reported hardware values")
        expect(near(healthy.maximumCapacity, 80) && healthy.capacityEstimated, "capacity-ratio health is explicitly identified as an estimate")
        expect(healthy.percent == 60 && healthy.maximumCapacity != healthy.percent, "current charge is never mistaken for maximum battery capacity")
        expect(healthy.fullCapacity == 6400 && healthy.designCapacity == 8000, "full-charge and design capacity retain their mAh values")
        health.health_state = 3
        expect(BatteryStatus(raw: health).healthDescription == "建议维修", "service recommendations take priority over a high capacity percentage")
        health.health_state = 4
        expect(BatteryStatus(raw: health).healthDescription == "需要维修", "permanent battery failures are identified")
        health.health_state = 0; health.capacity_source = 0; health.cycle_count = -1
        health.design_capacity_mah = 0; health.full_capacity_mah = 0
        let unknownHealth = BatteryStatus(raw: health)
        expect(unknownHealth.healthDescription == "系统未提供" && unknownHealth.maximumCapacity == nil && unknownHealth.cycleCount == nil, "missing health readings are not fabricated from charge percentage")
        health.cycle_count = 0
        expect(BatteryStatus(raw: health).cycleCount == 0, "zero cycles is a valid reading distinct from unavailable")
        health.capacity_source = 1; health.maximum_capacity_percent = 95
        expect(BatteryStatus(raw: health).maximumCapacity == 95 && !BatteryStatus(raw: health).capacityEstimated, "reported maximum capacity is distinct from an estimate")
        health.maximum_capacity_percent = .nan
        expect(BatteryStatus(raw: health).maximumCapacity == nil, "invalid health percentages do not render as valid readings")
        health.maximum_capacity_percent = 105
        expect(BatteryStatus(raw: health).maximumCapacity == nil, "out-of-range health percentages are rejected")
        health.design_capacity_mah = 7000; health.full_capacity_mah = 100
        expect(BatteryStatus(raw: health).fullCapacity == nil, "normalized 100 capacity is not mislabeled as mAh")
        health.present = 0
        expect(BatteryStatus(raw: health).cycleCount == nil && BatteryStatus(raw: health).healthDescription == "系统未提供", "no-battery Macs do not expose stale health readings")

        var interfaceCount = 0
        var networkValid: Int32 = 0
        if let interfaces = rb_network_samples(&interfaceCount, &networkValid) {
            let values = Array(UnsafeBufferPointer(start: interfaces, count: interfaceCount))
            expect(networkValid == 1, "real 64-bit interface snapshot is readable")
            expect(Set(values.map(\.index)).count == values.count, "real interface snapshot contains no duplicates")
            rb_free_network_samples(interfaces)
        } else { expect(networkValid == 1, "real interface enumeration") }
        let power = rb_battery_sample()
        expect(power.available == 1, "public IOKit power-source snapshot is readable")
        if power.present == 1 { expect(BatteryStatus(raw: power).percent != nil, "real internal battery percentage is valid") }
        print("\(passed) checks passed. No running applications were terminated.")
    }
}
