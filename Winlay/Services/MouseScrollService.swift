import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

/// Handles only discrete, unmodified hardware-style scroll events while enabled.
@MainActor final class MouseScrollService: ObservableObject {
    @Published private(set) var status = "未开启"
    private var settings = MouseScrollSettings()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var accumulator = SmoothScrollAccumulator()
    private var pendingFlags = CGEventFlags()
    private var pendingApplication: String?
    private var frontmostApplication: String?
    private var appActivationObserver: NSObjectProtocol?
    private var pendingDuration = 0.22
    private var lastTick = 0.0
    private let injectedMarker: Int64 = 0x57494e4c4159

    deinit {
        timer?.invalidate()
        if let observer = appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
    }

    func update(_ newSettings: MouseScrollSettings, promptForPermission: Bool = false) {
        if newSettings != settings { stopAnimation() }
        settings = newSettings
        guard settings.enabled else { stopTap(); status = "未开启"; return }
        if !AXIsProcessTrusted() {
            stopTap(); status = "需要辅助功能权限"
            if promptForPermission {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        guard let eventTap else { startTap(); return }
        if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
        status = "已开启"
    }

    func refreshAuthorization() {
        guard settings.enabled else { return }
        if !AXIsProcessTrusted() { stopTap(); status = "需要辅助功能权限" }
        else if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            status = "已开启"
        }
        else { startTap() }
    }
    func shutdown() { stopTap(); status = "未开启" }

    private func startTap() {
        let events = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let service = Unmanaged<MouseScrollService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handle(type: type, event: event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: events,
                                         callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = "无法启动滚轮处理，请检查辅助功能权限"
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); status = "无法启动滚轮处理"; return
        }
        eventTap = tap; runLoopSource = source
        frontmostApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frontmostApplication = bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                self.stopAnimation()
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status = "已开启"
    }

    private func stopTap() {
        stopAnimation()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        frontmostApplication = nil
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        runLoopSource = nil; eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopAnimation()
            if settings.enabled && AXIsProcessTrusted(), let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            else { status = "滚轮处理已暂停，请检查辅助功能权限" }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let metadata = ScrollEventMetadata(
            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous),
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            sourceProcessID: event.getIntegerValueField(.eventSourceUnixProcessID),
            sourceUserData: event.getIntegerValueField(.eventSourceUserData),
            modifierFlags: event.flags.rawValue)
        guard ScrollPolicy.shouldHandle(metadata) else { return Unmanaged.passUnretained(event) }
        let application = frontmostApplication ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let profile = ScrollPolicy.profile(for: metadata, settings: settings, application: application) else { return Unmanaged.passUnretained(event) }
        let originalY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let originalX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let originalZ = event.getIntegerValueField(.scrollWheelEventDeltaAxis3)
        guard originalX != 0 || originalY != 0 else { return Unmanaged.passUnretained(event) }

        let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let speed = profile.effectiveSpeed
        let smoothY = profile.smoothVertical && originalY != 0
        let smoothX = profile.smoothHorizontal && originalX != 0
        if smoothX || smoothY {
            let y = smoothY ? ScrollPolicy.signed(Double(pointY == 0 ? originalY : pointY) * (pointY == 0 ? 10 : 1), reverse: profile.reverseVertical, speed: speed) : 0
            let x = smoothX ? ScrollPolicy.signed(Double(pointX == 0 ? originalX : pointX) * (pointX == 0 ? 10 : 1), reverse: profile.reverseHorizontal, speed: speed) : 0
            enqueue(x: x, y: y, flags: event.flags, application: application, duration: profile.effectiveDuration)
        }
        transform(event, axis: 1, reverse: profile.reverseVertical, smooth: smoothY, speed: speed)
        transform(event, axis: 2, reverse: profile.reverseHorizontal, smooth: smoothX, speed: speed)
        if originalZ == 0 && ((smoothX && (smoothY || originalY == 0)) || (smoothY && originalX == 0)) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func transform(_ event: CGEvent, axis: Int, reverse: Bool, smooth: Bool, speed: Double) {
        let integerFields: [CGEventField] = axis == 1 ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1] : [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2]
        let fixedField: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        for field in integerFields {
            let original = event.getIntegerValueField(field)
            let value = smooth ? 0 : ScrollPolicy.signed(Double(original), reverse: reverse, speed: speed)
            let rounded = value.rounded()
            let nonzero = !smooth && original != 0 && rounded == 0 ? (value < 0 ? -1.0 : 1.0) : rounded
            event.setIntegerValueField(field, value: Int64(min(max(nonzero, -32767), 32767)))
        }
        let fixed = event.getDoubleValueField(fixedField)
        event.setDoubleValueField(fixedField, value: smooth ? 0 : ScrollPolicy.signed(fixed, reverse: reverse, speed: speed))
    }

    private func enqueue(x: Double, y: Double, flags: CGEventFlags, application: String?, duration: Double) {
        let relevantFlags = CGEventFlags(rawValue: ScrollPolicy.relevantModifiers(flags.rawValue))
        if !accumulator.isEmpty && (pendingApplication != application || pendingFlags != relevantFlags) { stopAnimation() }
        pendingFlags = relevantFlags; pendingApplication = application; pendingDuration = duration
        accumulator.add(x: x, y: y)
        guard !accumulator.isEmpty, timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let liveFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let currentApplication = frontmostApplication ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard settings.enabled, AXIsProcessTrusted(), !ScrollPolicy.hasUnsupportedModifier(liveFlags),
              pendingApplication == currentApplication else { stopAnimation(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let step = accumulator.next(elapsed: now - lastTick, duration: pendingDuration)
        lastTick = now
        if step.x != 0 || step.y != 0,
           let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: step.y, wheel2: step.x, wheel3: 0) {
            event.flags = pendingFlags
            event.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            event.post(tap: .cgSessionEventTap)
        }
        if accumulator.isEmpty { stopAnimation() }
    }

    private func stopAnimation() { timer?.invalidate(); timer = nil; accumulator.reset(); pendingApplication = nil }
}
