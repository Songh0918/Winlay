import Foundation

struct ScrollProfile: Codable, Equatable {
    var reverseVertical = true
    var reverseHorizontal = false
    var smoothVertical = true
    var smoothHorizontal = false
    var speed = 1.0
    var duration = 0.22

    var effectiveSpeed: Double { speed.isFinite ? min(max(speed, 0.25), 4) : 1 }
    var effectiveDuration: Double { duration.isFinite ? min(max(duration, 0.08), 0.6) : 0.22 }
}

struct ScrollApplicationRule: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var name: String
    var bypass = true
    var profile = ScrollProfile()
    var id: String { bundleIdentifier }
}

struct MouseScrollSettings: Codable, Equatable {
    var enabled = false
    var global = ScrollProfile()
    var applications: [ScrollApplicationRule] = []

    func profile(for bundleIdentifier: String?) -> ScrollProfile? {
        if let bundleIdentifier, let rule = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return rule.bypass ? nil : rule.profile
        }
        return global
    }
}

/// Quartz describes a scroll's format, not its physical device. Unknown, continuous,
/// gesture and injected events must pass through without attempting to change them.
struct ScrollEventMetadata {
    let continuous: Int64
    let phase: Int64
    let momentumPhase: Int64
    let sourceProcessID: Int64
    let sourceUserData: Int64
    let modifierFlags: UInt64
}

enum ScrollPolicy {
    // Command, Control and Option often mean zoom or app-specific gestures.
    static let unsupportedModifierMask: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
    // Shift is the only modifier forwarded across smooth-scroll ticks (e.g. horizontal scrolling).
    static let relevantModifierMask: UInt64 = 1 << 17

    static func hasUnsupportedModifier(_ flags: UInt64) -> Bool {
        (flags & unsupportedModifierMask) != 0
    }

    static func relevantModifiers(_ flags: UInt64) -> UInt64 {
        flags & relevantModifierMask
    }

    static func shouldHandle(_ event: ScrollEventMetadata) -> Bool {
        event.continuous == 0 && event.phase == 0 && event.momentumPhase == 0 &&
        event.sourceProcessID == 0 && event.sourceUserData == 0 &&
        !hasUnsupportedModifier(event.modifierFlags)
    }

    static func profile(for event: ScrollEventMetadata, settings: MouseScrollSettings, application: String?) -> ScrollProfile? {
        guard settings.enabled, shouldHandle(event) else { return nil }
        // If an app exception exists, an unknown foreground app must not inherit it accidentally.
        guard application != nil || settings.applications.isEmpty else { return nil }
        return settings.profile(for: application)
    }

    static func signed(_ value: Double, reverse: Bool, speed: Double) -> Double {
        value * (reverse ? -1 : 1) * speed
    }
}

/// Smoothly drains a bounded backlog without emitting zero-length or unbounded events.
struct SmoothScrollAccumulator {
    private(set) var x = 0.0
    private(set) var y = 0.0

    mutating func add(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        self.x = min(max(self.x + x, -12000), 12000)
        self.y = min(max(self.y + y, -12000), 12000)
    }

    mutating func next(elapsed: Double, duration: Double) -> (x: Int32, y: Int32) {
        guard elapsed.isFinite, elapsed > 0, duration.isFinite, duration > 0 else { return (0, 0) }
        let ratio = 1 - exp(-min(elapsed, 0.1) * 4.6 / duration)
        func step(_ pending: Double) -> Int32 {
            if abs(pending) < 1 { return Int32(pending.rounded()) }
            let value = (pending * ratio).rounded(.towardZero)
            return Int32(value == 0 ? (pending > 0 ? 1 : -1) : value)
        }
        let outputX = step(x), outputY = step(y)
        x -= Double(outputX); y -= Double(outputY)
        if abs(x) < 0.5 { x = 0 }; if abs(y) < 0.5 { y = 0 }
        return (outputX, outputY)
    }
    var isEmpty: Bool { x == 0 && y == 0 }
    mutating func reset() { x = 0; y = 0 }
}
