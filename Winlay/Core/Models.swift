import Foundation

public enum KeyboardMode: String, Codable, CaseIterable, Identifiable {
    case windows, mac, unchanged
    public var id: String { rawValue }
    public var title: String {
        switch self { case .windows: return "Mac 键位布局"; case .mac: return "Mac 原生"; case .unchanged: return "完全原样" }
    }
    // USB HID keyboard usages, represented independently of platform key codes.
    public var mappings: [KeyMapping] {
        switch self {
        case .windows: return [KeyMapping(source: 0xe2, destination: 0xe3), KeyMapping(source: 0xe3, destination: 0xe2), KeyMapping(source: 0xe6, destination: 0xe7), KeyMapping(source: 0xe7, destination: 0xe6)]
        case .mac: return []
        case .unchanged: return []
        }
    }
}

public struct KeyMapping: Codable, Equatable, Hashable {
    public let source: UInt64
    public let destination: UInt64
    public init(source: UInt64, destination: UInt64) { self.source = source; self.destination = destination }
}

public struct KeyRule: Codable, Equatable, Identifiable {
    public var source: UInt64
    public var destination: UInt64
    public var enabled: Bool
    public var id: UInt64 { source }
    public init(source: UInt64, destination: UInt64, enabled: Bool = true) {
        self.source = source; self.destination = destination; self.enabled = enabled
    }
}

public struct KeyboardProfile: Codable, Equatable {
    public var device: DeviceIdentity
    public var rules: [KeyRule]
}

public struct KeyboardKey: Identifiable, Sendable {
    public let id: UInt64
    public let windows: String
    public let mac: String
    public static let all: [KeyboardKey] = {
        var keys = (0..<26).map { n in KeyboardKey(id: UInt64(n + 4), windows: String(UnicodeScalar(65 + n)!), mac: String(UnicodeScalar(65 + n)!)) }
        keys += Array("1234567890").enumerated().map { n, c in KeyboardKey(id: UInt64(30 + n), windows: String(c), mac: String(c)) }
        let special: [(UInt64, String)] = [(40,"↩ Enter"),(41,"⎋ Esc"),(42,"⌫ Backspace"),(43,"⇥ Tab"),(44,"␣ Space"),(45,"-"),(46,"="),(47,"["),(48,"]"),(49,"\\"),(51,";"),(52,"'"),(53,"`"),(54,","),(55,"."),(56,"/"),(57,"⇪ Caps Lock"),(70,"Print Screen"),(71,"Scroll Lock"),(72,"Pause"),(73,"Insert"),(74,"↖ Home"),(75,"⇞ Page Up"),(76,"⌦ Delete"),(77,"↘ End"),(78,"⇟ Page Down"),(79,"→ 右方向键"),(80,"← 左方向键"),(81,"↓ 下方向键"),(82,"↑ 上方向键"),(83,"Num Lock"),(84,"小键盘 /"),(85,"小键盘 *"),(86,"小键盘 -"),(87,"小键盘 +"),(88,"⌤ 小键盘 Enter"),(89,"小键盘 1"),(90,"小键盘 2"),(91,"小键盘 3"),(92,"小键盘 4"),(93,"小键盘 5"),(94,"小键盘 6"),(95,"小键盘 7"),(96,"小键盘 8"),(97,"小键盘 9"),(98,"小键盘 0"),(99,"小键盘 .")]
        keys += special.map { KeyboardKey(id: $0.0, windows: $0.1, mac: $0.1) }
        keys += (1...12).map { KeyboardKey(id: UInt64(57 + $0), windows: "F\($0)", mac: "F\($0)") }
        keys += (13...24).map { KeyboardKey(id: UInt64(91 + $0), windows: "F\($0)", mac: "F\($0)") }
        keys += [(0xe0,"⌃ 左 Ctrl","⌃ 左 Control"),(0xe1,"⇧ 左 Shift","⇧ 左 Shift"),(0xe2,"左 Alt","⌥ 左 Option"),(0xe3,"⊞ 左 Win","⌘ 左 Command"),(0xe4,"⌃ 右 Ctrl","⌃ 右 Control"),(0xe5,"⇧ 右 Shift","⇧ 右 Shift"),(0xe6,"右 Alt","⌥ 右 Option"),(0xe7,"⊞ 右 Win","⌘ 右 Command")].map { KeyboardKey(id: UInt64($0.0), windows: $0.1, mac: $0.2) }
        return keys.sorted { $0.id < $1.id }
    }()
    public static func name(_ usage: UInt64, mac: Bool) -> String {
        guard let key = all.first(where: { $0.id == usage }) else { return String(format: "HID 0x%02llX", usage) }
        return mac ? key.mac : key.windows
    }
}

public struct KeyboardDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?
    public let transport: String
    public let builtIn: Bool?
    public init(id: String, name: String, vendorID: Int?, productID: Int?, locationID: Int?, transport: String, builtIn: Bool?) {
        self.id = id; self.name = name; self.vendorID = vendorID; self.productID = productID; self.locationID = locationID; self.transport = transport; self.builtIn = builtIn
    }
    public var matchingIdentity: DeviceIdentity? {
        guard (builtIn == true || builtIn == false || ["usb", "bluetooth"].contains(transport.lowercased())), let vendorID, vendorID > 0, let productID, productID > 0, let locationID, locationID > 0 else { return nil }
        return DeviceIdentity(vendorID: vendorID, productID: productID, locationID: locationID)
    }
}

public struct DeviceIdentity: Codable, Equatable, Hashable {
    public let vendorID: Int
    public let productID: Int
    public let locationID: Int
    public init(vendorID: Int, productID: Int, locationID: Int) { self.vendorID = vendorID; self.productID = productID; self.locationID = locationID }
    public func isUnique(in devices: [KeyboardDevice]) -> Bool {
        // Include internal and unknown devices in collision detection.
        devices.filter { $0.vendorID == vendorID && $0.productID == productID && $0.locationID == locationID }.count == 1
    }
    public func isCompatibleGroup(in devices: [KeyboardDevice]) -> Bool {
        let matches = devices.filter { $0.vendorID == vendorID && $0.productID == productID && $0.locationID == locationID }
        guard let first = matches.first, first.matchingIdentity == self else { return false }
        return matches.allSatisfy { $0.matchingIdentity == self && $0.name == first.name && $0.transport == first.transport && $0.builtIn == first.builtIn }
    }
}

public struct Configuration: Codable, Equatable {
    public static let currentVersion = 2
    public var schemaVersion: Int = currentVersion
    public var selectedDevice: DeviceIdentity?
    public var preferredMode: KeyboardMode = .unchanged
    public var onboardingComplete: Bool = false
    // Missing in older configurations means the original four mappings are enabled.
    public var enabledMappingSources: [UInt64]? = nil
    public var profiles: [KeyboardProfile]? = nil
    public var deviceRefreshInterval: Double? = nil
    public var showDockIcon: Bool? = nil
    public var showMenuBarIcon: Bool? = nil
    // Devices explicitly enabled by the user, retained across normal app restarts.
    public var enabledDevices: [DeviceIdentity]? = nil
    public var effectiveDeviceRefreshInterval: Double {
        guard let interval = deviceRefreshInterval, interval.isFinite, (0.5...30).contains(interval) else { return 2 }
        return interval
    }
    public var effectiveShowDockIcon: Bool { showDockIcon ?? false }
    public var effectiveShowMenuBarIcon: Bool { (showMenuBarIcon ?? true) || !effectiveShowDockIcon }
    public func rules(for device: DeviceIdentity) -> [KeyRule] {
        if let profile = profiles?.first(where: { $0.device == device }) { return profile.rules }
        let enabled = (profiles == nil && selectedDevice == device) ? enabledMappingSources : nil
        return KeyboardMode.windows.mappings.map { KeyRule(source: $0.source, destination: $0.destination, enabled: enabled?.contains($0.source) ?? true) }
    }
    public mutating func setRules(_ rules: [KeyRule], for device: DeviceIdentity) {
        if profiles == nil {
            let previous = selectedDevice.map { KeyboardProfile(device: $0, rules: self.rules(for: $0)) }
            profiles = previous.map { [$0] } ?? []
        }
        profiles?.removeAll { $0.device == device }
        profiles?.append(KeyboardProfile(device: device, rules: rules))
    }
    public var selectedMappings: [KeyMapping] {
        if let selectedDevice { return rules(for: selectedDevice).filter(\.enabled).map { KeyMapping(source: $0.source, destination: $0.destination) } }
        let defaults = KeyboardMode.windows.mappings
        guard let enabledMappingSources else { return defaults }
        let enabled = Set(enabledMappingSources)
        return defaults.filter { enabled.contains($0.source) }
    }
    public init() {}
}

public enum ConfigurationError: LocalizedError {
    case unsupportedVersion(Int)
    public var errorDescription: String? { switch self { case .unsupportedVersion(let version): return "不支持的配置版本：\(version)" } }
}

public struct ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let data = try Data(contentsOf: url)
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        guard version == 1 || version == Configuration.currentVersion else { throw ConfigurationError.unsupportedVersion(version) }
        var configuration = try JSONDecoder().decode(Configuration.self, from: data)
        configuration.schemaVersion = Configuration.currentVersion
        return configuration
    }
    public func save(_ configuration: Configuration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
    private struct Version: Decodable { let schemaVersion: Int }
}

public enum RestoreDecision: Equatable {
    case restore, alreadyRestored, conflict
    public static func decide(current: [KeyMapping], applied: [KeyMapping], original: [KeyMapping]) -> RestoreDecision {
        if current == original { return .alreadyRestored }
        return current == applied ? .restore : .conflict
    }
}
