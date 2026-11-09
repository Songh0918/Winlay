import Foundation

/// A complete device snapshot, written before any change so an interrupted update can be recovered.
public struct MappingJournal: Codable, Equatable {
    public let device: DeviceIdentity
    public let original: [KeyMapping]
    public let applied: [KeyMapping]
    public let serviceCount: Int?
    public init(device: DeviceIdentity, original: [KeyMapping], applied: [KeyMapping], serviceCount: Int? = nil) {
        self.device = device; self.original = original; self.applied = applied; self.serviceCount = serviceCount
    }
    public func matchesApplied(states: [[KeyMapping]]) -> Bool {
        func normalized(_ mappings: [KeyMapping]) -> [KeyMapping] {
            mappings.sorted { $0.source == $1.source ? $0.destination < $1.destination : $0.source < $1.source }
        }
        return !states.isEmpty && states.count == (serviceCount ?? 1)
            && states.allSatisfy { normalized($0) == normalized(applied) }
    }
}

public protocol DeviceMappingBackend {
    func read(device: DeviceIdentity) throws -> [KeyMapping]
    func readStates(device: DeviceIdentity) throws -> [[KeyMapping]]
    func write(device: DeviceIdentity, mappings: [KeyMapping]) throws
}
public extension DeviceMappingBackend {
    func readStates(device: DeviceIdentity) throws -> [[KeyMapping]] { [try read(device: device)] }
}
public protocol MappingJournalStore {
    func load() throws -> MappingJournal?
    func save(_ journal: MappingJournal) throws
    func remove() throws
}
public enum MappingTransactionError: LocalizedError {
    case alreadyActive, duplicateSource, conflictingSource, changedExternally, verificationFailed
    public var errorDescription: String? {
        switch self {
        case .alreadyActive: return "存在尚未恢复的映射记录。"
        case .duplicateSource: return "同一个来源按键存在重复定义。"
        case .conflictingSource: return "已有映射占用了相同的来源按键。"
        case .changedExternally: return "键位已被其他程序更改；Winlay 不会覆盖。"
        case .verificationFailed: return "设备映射读取结果与写入结果不一致。"
        }
    }
}

public struct MappingTransaction {
    private let backend: any DeviceMappingBackend
    private let journal: any MappingJournalStore
    public init(backend: any DeviceMappingBackend, journal: any MappingJournalStore) {
        self.backend = backend; self.journal = journal
    }
    private func normalized(_ mappings: [KeyMapping]) -> [KeyMapping] {
        mappings.sorted { $0.source == $1.source ? $0.destination < $1.destination : $0.source < $1.source }
    }
    public func apply(device: DeviceIdentity, mappings: [KeyMapping]) throws {
        guard try journal.load() == nil else { throw MappingTransactionError.alreadyActive }
        guard Set(mappings.map(\.source)).count == mappings.count else { throw MappingTransactionError.duplicateSource }
        let states = try backend.readStates(device: device).map(normalized)
        guard let original = states.first, states.allSatisfy({ $0 == original }) else { throw MappingTransactionError.changedExternally }
        guard Set(original.map(\.source)).count == original.count else { throw MappingTransactionError.duplicateSource }
        guard Set(original.map(\.source)).isDisjoint(with: mappings.map(\.source)) else { throw MappingTransactionError.conflictingSource }
        let expected = normalized(original + mappings)
        try journal.save(MappingJournal(device: device, original: normalized(original), applied: expected, serviceCount: states.count))
        // Do not write if another actor changed the device after the snapshot.
        guard try backend.readStates(device: device).map(normalized) == states else { throw MappingTransactionError.changedExternally }
        try backend.write(device: device, mappings: expected)
        let after = try backend.readStates(device: device).map(normalized)
        guard after.count == states.count, after.allSatisfy({ $0 == expected }) else { throw MappingTransactionError.verificationFailed }
    }
    public func restore() throws {
        guard let saved = try journal.load() else { return }
        let current = try backend.readStates(device: saved.device).map(normalized)
        guard !current.isEmpty, current.count == (saved.serviceCount ?? 1) else { throw MappingTransactionError.changedExternally }
        if current.allSatisfy({ $0 == normalized(saved.original) }) { try journal.remove(); return }
        guard current.allSatisfy({ $0 == normalized(saved.applied) || $0 == normalized(saved.original) }) else { throw MappingTransactionError.changedExternally }
        try backend.write(device: saved.device, mappings: saved.original)
        let restored = try backend.readStates(device: saved.device).map(normalized)
        guard restored.count == current.count, restored.allSatisfy({ $0 == normalized(saved.original) }) else { throw MappingTransactionError.verificationFailed }
        try journal.remove()
    }
}

public struct FileMappingJournalStore: MappingJournalStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> MappingJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MappingJournal.self, from: Data(contentsOf: url))
    }
    public func save(_ journal: MappingJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
