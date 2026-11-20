import CoreGraphics
import Foundation

@main struct ScrollScenarios {
    @MainActor static func main() throws {
        func metadata(continuous: Int64 = 0, phase: Int64 = 0, momentum: Int64 = 0,
                      pid: Int64 = 0, data: Int64 = 0, flags: UInt64 = 0) -> ScrollEventMetadata {
            ScrollEventMetadata(continuous: continuous, phase: phase, momentumPhase: momentum,
                                sourceProcessID: pid, sourceUserData: data, modifierFlags: flags)
        }
        precondition(ScrollPolicy.shouldHandle(metadata()))
        precondition(!ScrollPolicy.shouldHandle(metadata(continuous: 1)))
        precondition(!ScrollPolicy.shouldHandle(metadata(phase: 1)))
        precondition(!ScrollPolicy.shouldHandle(metadata(momentum: 1)))
        precondition(!ScrollPolicy.shouldHandle(metadata(pid: 12)))
        precondition(!ScrollPolicy.shouldHandle(metadata(data: 42)))
        precondition(!ScrollPolicy.shouldHandle(metadata(flags: 1 << 20)))
        precondition(ScrollPolicy.shouldHandle(metadata(flags: 1 << 17)))
        precondition(ScrollPolicy.hasUnsupportedModifier(1 << 20))
        precondition(ScrollPolicy.hasUnsupportedModifier(1 << 18))
        precondition(ScrollPolicy.hasUnsupportedModifier(1 << 19))
        precondition(!ScrollPolicy.hasUnsupportedModifier(1 << 17))
        precondition(ScrollPolicy.relevantModifiers((1 << 17) | 0x100) == (1 << 17))
        precondition(ScrollPolicy.relevantModifiers(0x100) == 0)

        var settings = MouseScrollSettings()
        precondition(!settings.enabled && settings.global.reverseVertical)
        var custom = ScrollProfile(); custom.speed = 1.75; custom.reverseVertical = false
        settings.applications = [ScrollApplicationRule(bundleIdentifier: "example.ignore", name: "Ignore"),
                                 ScrollApplicationRule(bundleIdentifier: "example.custom", name: "Custom", bypass: false, profile: custom)]
        precondition(settings.profile(for: "example.ignore") == nil)
        precondition(settings.profile(for: "example.custom") == custom)
        precondition(settings.profile(for: "example.other") == settings.global)
        precondition(ScrollPolicy.profile(for: metadata(), settings: settings, application: "example.other") == nil)
        settings.enabled = true
        precondition(ScrollPolicy.profile(for: metadata(), settings: settings, application: "example.custom") == custom)
        precondition(ScrollPolicy.profile(for: metadata(), settings: settings, application: "example.ignore") == nil)
        precondition(ScrollPolicy.profile(for: metadata(), settings: settings, application: nil) == nil)
        precondition(ScrollPolicy.profile(for: metadata(continuous: 1), settings: settings, application: "example.custom") == nil)
        let decoded = try JSONDecoder().decode(MouseScrollSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings)
        let legacy = try JSONDecoder().decode(Configuration.self, from: Data("{\"schemaVersion\":2,\"preferredMode\":\"unchanged\",\"onboardingComplete\":true}".utf8))
        precondition(!(legacy.mouseScroll ?? MouseScrollSettings()).enabled)

        var accumulator = SmoothScrollAccumulator()
        accumulator.add(x: -250, y: 500)
        var x: Int32 = 0, y: Int32 = 0
        for _ in 0..<600 {
            let step = accumulator.next(elapsed: 1.0 / 60, duration: 0.22)
            precondition(step.x <= 0 && step.y >= 0)
            x += step.x; y += step.y
            if accumulator.isEmpty { break }
        }
        precondition(accumulator.isEmpty && x == -250 && y == 500)
        accumulator.add(x: 1_000_000, y: -1_000_000)
        precondition(accumulator.x == 12000 && accumulator.y == -12000)
        accumulator.reset(); accumulator.add(x: .nan, y: 1)
        precondition(accumulator.isEmpty)

        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0) else {
            throw NSError(domain: "ScrollScenarios", code: 1)
        }
        let service = MouseScrollService()
        service.transform(event, axis: 1, reverse: true, smooth: false, speed: 1)
        precondition(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3)
        precondition(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -2)
        service.transform(event, axis: 2, reverse: false, smooth: true, speed: 1)
        precondition(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
        precondition(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
        precondition(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0)
        print("通过：事件放行、应用例外、旧配置、平滑收敛和横纵轴变换。")
    }
}
