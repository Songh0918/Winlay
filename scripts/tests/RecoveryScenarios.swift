import Foundation

enum SectionID { case overview }

final class ScenarioBackend: DeviceMappingBackend {
    var states: [DeviceIdentity: [[KeyMapping]]] = [:]
    var writes: [DeviceIdentity: Int] = [:]
    func read(device: DeviceIdentity) throws -> [KeyMapping] { try readStates(device: device)[0] }
    func readStates(device: DeviceIdentity) throws -> [[KeyMapping]] {
        guard let state = states[device] else { throw HIDMappingError(message: "设备未连接") }
        return state
    }
    func write(device: DeviceIdentity, mappings: [KeyMapping]) throws {
        guard let current = states[device] else { throw HIDMappingError(message: "设备未连接") }
        states[device] = current.map { _ in mappings }
        writes[device, default: 0] += 1
    }
}

@main struct RecoveryScenarios {
    @MainActor static func main() throws {
        precondition(!SystemAppearance.usesGlass(majorVersion: 15))
        precondition(SystemAppearance.usesGlass(majorVersion: 26) && SystemAppearance.usesGlass(majorVersion: 27))
        precondition(!SystemAppearance.usesGlass(majorVersion: 28))
        precondition(!SystemAppearance.usesGlass(majorVersion: 26, hasMetalDevice: false))
        precondition(!SystemAppearance.usesGlass(majorVersion: 26, reduceTransparency: true))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("winlay-scenarios-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let first = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        let second = DeviceIdentity(vendorID: 4, productID: 5, locationID: 6)
        let moved = DeviceIdentity(vendorID: 1, productID: 2, locationID: 7)
        func device(_ id: DeviceIdentity, _ suffix: String = "") -> KeyboardDevice {
            KeyboardDevice(id: "\(id.locationID)\(suffix)", name: "测试键盘", vendorID: id.vendorID, productID: id.productID, locationID: id.locationID, transport: "USB", builtIn: false)
        }
        func configuration(_ ids: [DeviceIdentity], root: URL) throws {
            var config = Configuration(); config.selectedDevice = ids.first; config.enabledDevices = ids; config.onboardingComplete = true
            try ConfigurationStore(url: root.appendingPathComponent("configuration.json")).save(config)
        }
        func journal(_ id: DeviceIdentity, root: URL) -> URL {
            root.appendingPathComponent("mapping-journals/v\(id.vendorID)-p\(id.productID)-l\(id.locationID).json")
        }

        // A keyboard that appears after login is resumed only after its old journal is safely reconciled.
        let delayedRoot = base.appendingPathComponent("delayed")
        try configuration([first], root: delayedRoot)
        let prior = MappingJournal(device: first, original: [], applied: KeyboardMode.windows.mappings, serviceCount: 2)
        try FileMappingJournalStore(url: journal(first, root: delayedRoot)).save(prior)
        let delayed = ScenarioBackend(); delayed.states[first] = [[], []]
        var detected: [KeyboardDevice] = []
        let model = AppModel(root: delayedRoot, deviceProvider: { detected }, backend: delayed, observeSystemEvents: false)
        precondition(model.activeDevices.isEmpty && delayed.writes.isEmpty)
        precondition(FileManager.default.fileExists(atPath: journal(first, root: delayedRoot).path))
        detected = [device(first), device(first, "b")]; model.refreshDevices()
        precondition(model.activeDevices.contains(first) && delayed.writes[first] == 1)
        let resumedStates = try delayed.readStates(device: first)
        precondition(prior.matchesApplied(states: resumedStates))

        // A different device state after wake must never be overwritten or reported as active.
        let external = [KeyMapping(source: 4, destination: 5)]
        delayed.states[first] = [external, external]
        model.refreshAfterWake()
        precondition(!model.activeDevices.contains(first) && delayed.writes[first] == 1)
        precondition(model.mappingMessage?.contains("唤醒") == true)
        precondition(FileManager.default.fileExists(atPath: journal(first, root: delayedRoot).path))

        // Moving a keyboard to another USB location never causes automatic migration.
        let movedRoot = base.appendingPathComponent("moved")
        try configuration([first], root: movedRoot)
        try FileMappingJournalStore(url: journal(first, root: movedRoot)).save(prior)
        let movedBackend = ScenarioBackend(); movedBackend.states[moved] = [[], []]
        let movedModel = AppModel(root: movedRoot, deviceProvider: { [device(moved)] }, backend: movedBackend, observeSystemEvents: false)
        precondition(movedModel.activeDevices.isEmpty && movedBackend.writes.isEmpty)
        precondition(FileManager.default.fileExists(atPath: journal(first, root: movedRoot).path))
        precondition(movedModel.mappingReason.contains("未连接"))

        // Ambiguous devices with the same identity but different names are never modified.
        let ambiguousRoot = base.appendingPathComponent("ambiguous")
        try configuration([first], root: ambiguousRoot)
        let ambiguousBackend = ScenarioBackend(); ambiguousBackend.states[first] = [[], []]
        let collision = KeyboardDevice(id: "collision", name: "另一设备", vendorID: first.vendorID, productID: first.productID, locationID: first.locationID, transport: "USB", builtIn: false)
        let ambiguous = AppModel(root: ambiguousRoot, deviceProvider: { [device(first), collision] }, backend: ambiguousBackend, observeSystemEvents: false)
        precondition(ambiguous.activeDevices.isEmpty && ambiguousBackend.writes.isEmpty)

        // One failed device must not clear the healthy state of a second keyboard.
        let multiRoot = base.appendingPathComponent("multi")
        try configuration([first, second], root: multiRoot)
        let multi = ScenarioBackend(); multi.states[first] = [[], []]; multi.states[second] = [[], []]
        var both = [device(first), device(first, "b"), device(second), device(second, "b")]
        let multiModel = AppModel(root: multiRoot, deviceProvider: { both }, backend: multi, observeSystemEvents: false)
        precondition(multiModel.activeDevices == Set([first, second]))
        multi.states[first] = [external, external]
        multiModel.refreshAfterWake()
        precondition(multiModel.activeDevices == Set([second]))
        precondition(multi.writes[first] == 1 && multi.writes[second] == 1)
        both = [device(first), device(first, "b")]; multiModel.refreshDevices()
        precondition(!multiModel.activeDevices.contains(second))
        both.append(contentsOf: [device(second), device(second, "b")]); multiModel.refreshDevices()
        precondition(!multiModel.activeDevices.contains(second) && multi.writes[second] == 1)

        // A failed restore clears only the uncertain active status and keeps the journal.
        let failureRoot = base.appendingPathComponent("failure")
        try configuration([first, second], root: failureRoot)
        let failure = ScenarioBackend(); failure.states[first] = [[], []]; failure.states[second] = [[], []]
        let failureModel = AppModel(root: failureRoot, deviceProvider: { [device(first), device(first, "b"), device(second), device(second, "b")] }, backend: failure, observeSystemEvents: false)
        failure.states[first] = [external, external]
        failureModel.restoreAllMappings()
        precondition(failureModel.activeDevices.isEmpty && failure.writes[first] == 1 && failure.writes[second] == 2)
        precondition(FileManager.default.fileExists(atPath: journal(first, root: failureRoot).path))
        precondition(!FileManager.default.fileExists(atPath: journal(second, root: failureRoot).path))
        precondition(failureModel.mappingMessage?.contains("无法恢复") == true)
        print("通过：延迟连接、唤醒冲突、USB 换位、设备身份冲突、多键盘、断线重连及部分恢复失败。")
    }
}
