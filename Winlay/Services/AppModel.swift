import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    @Published var selection: SectionID? = .overview
    @Published var devices: [KeyboardDevice] = []
    @Published var configuration = Configuration()
    @Published var errorMessage: String?
    @Published var loginStatus = "未检查"
    @Published var showingOnboarding = false
    @Published private(set) var activeDevices: Set<DeviceIdentity> = []
    @Published var mappingMessage: String?
    private let deviceManager: KeyboardDeviceManager
    private let deviceProvider: () -> [KeyboardDevice]
    private let backend: any DeviceMappingBackend
    private let root: URL
    private let store: ConfigurationStore
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var configurationWritable = true
    private var disconnectedDevices: Set<DeviceIdentity> = []
    private var pendingStartupDevices: Set<DeviceIdentity> = []

    init(root: URL? = nil, deviceProvider: (() -> [KeyboardDevice])? = nil,
         backend: any DeviceMappingBackend = HIDMappingBackend(), observeSystemEvents: Bool = true) {
        let manager = KeyboardDeviceManager()
        deviceManager = manager
        self.deviceProvider = deviceProvider ?? { manager.devices() }
        self.backend = backend
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Winlay")
        store = ConfigurationStore(url: self.root.appendingPathComponent("configuration.json"))
        do { configuration = try store.load() } catch { errorMessage = "配置读取失败，已停止覆盖原文件：\(error.localizedDescription)"; configurationWritable = false }
        showingOnboarding = !configuration.onboardingComplete
        if observeSystemEvents { refresh() } else { refreshDevices() }
        recoverOnStart()
        if observeSystemEvents {
            scheduleDeviceRefresh()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshAfterWake() } }
        }
    }
    private func scheduleDeviceRefresh() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: configuration.effectiveDeviceRefreshInterval, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshDevices() } }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }
    func setDeviceRefreshInterval(_ interval: Double) {
        guard configurationWritable, interval.isFinite, (0.5...30).contains(interval) else { return }
        guard interval != configuration.effectiveDeviceRefreshInterval else { return }
        configuration.deviceRefreshInterval = interval
        scheduleDeviceRefresh()
        save()
    }
    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = configuration.effectiveShowDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        if !NSApp.setActivationPolicy(policy) {
            configuration.showDockIcon = false
            configuration.showMenuBarIcon = true
            errorMessage = "无法更新程序坞图标，已保留菜单栏入口。"
        }
    }
    func setDockIconVisible(_ visible: Bool) {
        guard configurationWritable else { return }
        guard visible != configuration.effectiveShowDockIcon else { return }
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        let currentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let wasVisible = currentWindow?.isVisible == true
        guard NSApp.setActivationPolicy(policy) else { errorMessage = "无法更新程序坞图标。"; return }
        configuration.showDockIcon = visible
        if !visible && configuration.showMenuBarIcon == false { configuration.showMenuBarIcon = true }
        save()
        if wasVisible, let window = currentWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak window] in
                guard let window, !window.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
    func setMenuBarIconVisible(_ visible: Bool) {
        guard configurationWritable else { return }
        guard visible || configuration.effectiveShowDockIcon else { errorMessage = "请至少保留一个程序坞或菜单栏图标，以便重新打开 Winlay。"; return }
        guard visible != configuration.effectiveShowMenuBarIcon else { return }
        configuration.showMenuBarIcon = visible
        save()
    }
    private var legacyJournal: URL { root.appendingPathComponent("mapping-journal.json") }
    private var journalDirectory: URL { root.appendingPathComponent("mapping-journals", isDirectory: true) }
    private func journalURL(_ id: DeviceIdentity) -> URL {
        journalDirectory.appendingPathComponent("v\(id.vendorID)-p\(id.productID)-l\(id.locationID).json")
    }
    private func transaction(_ url: URL) -> MappingTransaction { MappingTransaction(backend: backend, journal: FileMappingJournalStore(url: url)) }
    private func journalURLs() throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = fm.fileExists(atPath: legacyJournal.path) ? [legacyJournal] : []
        if fm.fileExists(atPath: journalDirectory.path) {
            result += try fm.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return result
    }
    var hasRecovery: Bool { (try? journalURLs().isEmpty) != true }
    var hasConnectedRecovery: Bool {
        guard let urls = try? journalURLs() else { return true }
        return urls.contains { url in
            guard let saved = try? FileMappingJournalStore(url: url).load() else { return true }
            return devices.contains { $0.matchingIdentity == saved.device }
        }
    }
    var selectedHasRecovery: Bool {
        guard let identity = configuration.selectedDevice else { return false }
        if FileManager.default.fileExists(atPath: journalURL(identity).path) { return true }
        if FileManager.default.fileExists(atPath: legacyJournal.path) {
            guard let old = try? FileMappingJournalStore(url: legacyJournal).load() else { return true }
            return old.device == identity
        }
        return false
    }
    var selectedDevice: KeyboardDevice? { devices.first { $0.matchingIdentity == configuration.selectedDevice && configuration.selectedDevice != nil } }
    var mappingActive: Bool { configuration.selectedDevice.map { activeDevices.contains($0) } ?? false }
    var currentRules: [KeyRule] { configuration.selectedDevice.map { configuration.rules(for: $0) } ?? [] }
    var status: String {
        if errorMessage != nil { return "异常" }
        if mappingActive { return "当前键盘已应用" }
        if selectedHasRecovery { return "当前键盘恢复待处理" }
        if devices.isEmpty { return "未检测到键盘" }
        return "当前键盘已暂停"
    }
    var mappingReason: String {
        if let mappingMessage { return mappingMessage }
        if mappingActive { return "当前键盘的映射已应用；其他键盘可独立设置。" }
        if selectedHasRecovery { return "当前键盘有待恢复的映射，请先恢复。" }
        guard let device = selectedDevice, let identity = device.matchingIdentity else {
            return configuration.selectedDevice == nil ? "请选择可识别的键盘。" : "之前选择的键盘未在原连接位置找到；如果更换了接口，请在设备中重新选择键盘并启用映射。"
        }
        guard identity.isCompatibleGroup(in: devices) else { return "设备标识存在冲突，不能启用映射。" }
        guard !configuration.selectedMappings.isEmpty else { return "请先启用至少一条映射。" }
        return "已选择 \(configuration.selectedMappings.count) 条按键映射。"
    }
    var canApply: Bool { guard configurationWritable, !configuration.selectedMappings.isEmpty, !mappingActive, !selectedHasRecovery, let device = selectedDevice, let identity = device.matchingIdentity else { return false }; return identity.isCompatibleGroup(in: devices) }
    func refreshDevices() {
        let current = deviceProvider()
        if current != devices { devices = current }
        let missing = activeDevices.filter { identity in !current.contains { $0.matchingIdentity == identity } }
        if !missing.isEmpty { activeDevices.subtract(missing); disconnectedDevices.formUnion(missing); mappingMessage = "键盘已断开；恢复记录已保留，请重新连接后恢复。" }
        let returned = disconnectedDevices.filter { identity in current.contains { $0.matchingIdentity == identity } }
        if !returned.isEmpty { disconnectedDevices.subtract(returned); mappingMessage = "键盘已重新连接，请先恢复映射，再重新启用。" }
        resumeStartupDevices()
    }
    func applyWindows() {
        guard canApply, let identity = selectedDevice?.matchingIdentity else { return }
        do {
            try transaction(journalURL(identity)).apply(device: identity, mappings: configuration.selectedMappings)
            activeDevices.insert(identity)
            var enabled = configuration.enabledDevices ?? []
            if !enabled.contains(identity) { enabled.append(identity) }
            configuration.enabledDevices = enabled
            save(); mappingMessage = nil
        }
        catch { mappingMessage = "无法启用映射：\(error.localizedDescription)" }
    }
    func verifyCurrentMapping() {
        guard mappingActive, let identity = configuration.selectedDevice else { return }
        do {
            guard let saved = try FileMappingJournalStore(url: journalURL(identity)).load(), saved.device == identity else {
                throw HIDMappingError(message: "找不到当前键盘的恢复记录。")
            }
            let states = try backend.readStates(device: identity)
            guard saved.matchesApplied(states: states) else {
                activeDevices.remove(identity)
                mappingMessage = "系统映射已变化或接口数量改变；请检查后恢复，Winlay 不会覆盖其他程序的修改。"
                return
            }
            mappingMessage = "系统中各接口的映射与记录一致；实际快捷键仍需在目标应用中验证。"
        } catch {
            mappingMessage = "无法检查系统映射：\(error.localizedDescription)"
        }
    }
    func restoreMapping() {
        guard let identity = configuration.selectedDevice else { return }
        do {
            let old = try FileMappingJournalStore(url: legacyJournal).load()
            let url = old?.device == identity ? legacyJournal : journalURL(identity)
            try transaction(url).restore(); activeDevices.remove(identity)
            pendingStartupDevices.remove(identity)
            configuration.enabledDevices?.removeAll { $0 == identity }
            save(); mappingMessage = nil
        }
        catch { activeDevices.remove(identity); mappingMessage = "无法恢复映射：\(error.localizedDescription)" }
    }
    func restoreAllMappings() {
        do {
            var failures: [String] = []
            var offline = 0
            for url in try journalURLs() {
                do {
                    guard let saved = try FileMappingJournalStore(url: url).load() else { continue }
                    guard devices.contains(where: { $0.matchingIdentity == saved.device }) else { offline += 1; continue }
                    do { try transaction(url).restore(); activeDevices.remove(saved.device) }
                    catch { activeDevices.remove(saved.device); throw error }
                } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { mappingMessage = "部分设备无法恢复：\(failures.joined(separator: "；"))" }
            else if offline > 0 { mappingMessage = "有 \(offline) 条旧设备恢复记录：设备未连接，记录已保留；不会修改其他设备的映射。" }
            else { mappingMessage = nil }
        } catch { mappingMessage = "无法检查恢复记录：\(error.localizedDescription)" }
    }
    func refreshAfterWake() {
        refresh()
        var needsAttention = false
        for identity in activeDevices {
            do {
                guard let saved = try FileMappingJournalStore(url: journalURL(identity)).load(),
                      saved.matchesApplied(states: try backend.readStates(device: identity)) else {
                    activeDevices.remove(identity); needsAttention = true; continue
                }
            } catch { activeDevices.remove(identity); needsAttention = true }
        }
        if needsAttention { mappingMessage = "唤醒后部分键盘映射发生变化或暂时无法读取；恢复记录已保留，请检查后恢复并重新启用。" }
    }
    func recoverOnStart() {
        if hasRecovery { restoreAllMappings() }
        guard configurationWritable else { return }
        pendingStartupDevices = Set(configuration.enabledDevices ?? [])
        resumeStartupDevices()
    }
    private func resumeStartupDevices() {
        for identity in pendingStartupDevices {
            guard identity.isCompatibleGroup(in: devices) else { continue }
            pendingStartupDevices.remove(identity)
            let mappings = configuration.rules(for: identity).filter(\.enabled).map { KeyMapping(source: $0.source, destination: $0.destination) }
            guard !mappings.isEmpty else { continue }
            do {
                if let legacy = try FileMappingJournalStore(url: legacyJournal).load(), legacy.device == identity {
                    try transaction(legacyJournal).restore()
                }
                let url = journalURL(identity)
                try transaction(url).restore()
                try transaction(url).apply(device: identity, mappings: mappings)
                activeDevices.insert(identity)
            }
            catch { mappingMessage = "无法自动启用键盘映射：\(error.localizedDescription)" }
        }
    }
    func setRules(_ rules: [KeyRule]) {
        guard configurationWritable, let identity = selectedDevice?.matchingIdentity else { mappingMessage = "请先选择键盘。"; return }
        guard !selectedHasRecovery || mappingActive else { mappingMessage = "请先恢复当前键盘的映射。"; return }
        guard Set(rules.map(\.source)).count == rules.count else { mappingMessage = "同一个输入按键只能设置一条规则。"; return }
        guard rules.allSatisfy({ $0.source != $0.destination }) else { mappingMessage = "输入和输出按键不能相同。"; return }
        guard rules != currentRules else { return }
        let newMappings = rules.filter(\.enabled).map { KeyMapping(source: $0.source, destination: $0.destination) }
        if mappingActive {
            do {
                try transaction(journalURL(identity)).restore()
                activeDevices.remove(identity)
                if !newMappings.isEmpty { try transaction(journalURL(identity)).apply(device: identity, mappings: newMappings); activeDevices.insert(identity) }
            } catch { activeDevices.remove(identity); mappingMessage = "无法更新映射：\(error.localizedDescription)"; return }
        }
        configuration.setRules(rules, for: identity)
        if newMappings.isEmpty { configuration.enabledDevices?.removeAll { $0 == identity }; pendingStartupDevices.remove(identity) }
        mappingMessage = nil
        save()
    }
    func setRuleEnabled(_ source: UInt64, enabled: Bool) {
        var rules = currentRules
        guard let index = rules.firstIndex(where: { $0.source == source }) else { return }
        rules[index].enabled = enabled
        setRules(rules)
    }
    func removeRule(_ source: UInt64) { setRules(currentRules.filter { $0.source != source }) }
    func addRule(source: UInt64, destination: UInt64) {
        guard KeyboardKey.all.contains(where: { $0.id == source }), KeyboardKey.all.contains(where: { $0.id == destination }) else { mappingMessage = "不支持的按键。"; return }
        setRules(currentRules + [KeyRule(source: source, destination: destination)])
    }
    func refresh() { refreshDevices(); updateLoginStatus() }
    func select(_ device: KeyboardDevice) {
        guard let identity = device.matchingIdentity, identity.isCompatibleGroup(in: devices) else { return }
        // Materialize the legacy selected profile before changing devices.
        if configuration.profiles == nil, let previous = configuration.selectedDevice { configuration.setRules(configuration.rules(for: previous), for: previous) }
        configuration.selectedDevice = identity; mappingMessage = nil; save()
    }
    func completeOnboarding() { configuration.onboardingComplete = true; save(); showingOnboarding = false }
    private func save() {
        guard configurationWritable else { return }
        do { try store.save(configuration) } catch { errorMessage = "配置保存失败：\(error.localizedDescription)"; configurationWritable = false }
    }
    func updateLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "已开启"
        case .notRegistered: loginStatus = "未开启"
        case .requiresApproval: loginStatus = "需要在系统设置中批准"
        case .notFound: loginStatus = "不可用"
        @unknown default: loginStatus = "未知"
        }
    }
    func setLogin(enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { errorMessage = "登录项设置失败：\(error.localizedDescription)" }
        updateLoginStatus()
    }
}
