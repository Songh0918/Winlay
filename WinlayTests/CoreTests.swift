import XCTest
@testable import WinlayCore

final class CoreTests: XCTestCase {
    func testMacPositionMappingsSwapAltAndWinOnBothSides() {
        XCTAssertEqual(KeyboardMode.windows.mappings, [KeyMapping(source: 0xe2, destination: 0xe3), KeyMapping(source: 0xe3, destination: 0xe2), KeyMapping(source: 0xe6, destination: 0xe7), KeyMapping(source: 0xe7, destination: 0xe6)])
        XCTAssertTrue(KeyboardMode.unchanged.mappings.isEmpty)
    }
    func testDeviceIdentityRequiresCompleteAndConsistentIdentity() {
        let external = device(id: "1", builtIn: false)
        XCTAssertNotNil(external.matchingIdentity)
        XCTAssertNotNil(device(id: "2", builtIn: true).matchingIdentity)
        XCTAssertNotNil(device(id: "3", builtIn: nil).matchingIdentity)
        XCTAssertTrue(external.matchingIdentity!.isUnique(in: [external]))
        XCTAssertFalse(external.matchingIdentity!.isUnique(in: [external, device(id: "2", builtIn: true)]))
        XCTAssertFalse(external.matchingIdentity!.isCompatibleGroup(in: [external, device(id: "3", builtIn: nil)]))
        XCTAssertTrue(external.matchingIdentity!.isCompatibleGroup(in: [external, device(id: "4", builtIn: false)]))
        XCTAssertFalse(external.matchingIdentity!.isCompatibleGroup(in: [external, device(id: "2", builtIn: true)]))
    }
    func testRestoreOnlyWhenOwnedValueStillPresent() {
        let original = [KeyMapping(source: 1, destination: 2)], applied = [KeyMapping(source: 1, destination: 3)]
        XCTAssertEqual(RestoreDecision.decide(current: applied, applied: applied, original: original), .restore)
        XCTAssertEqual(RestoreDecision.decide(current: original, applied: applied, original: original), .alreadyRestored)
        XCTAssertEqual(RestoreDecision.decide(current: [], applied: applied, original: original), .conflict)
    }
    func testReadOnlyMappingCheckVerifiesEveryService() {
        let id = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        let a = KeyMapping(source: 1, destination: 2), b = KeyMapping(source: 3, destination: 4)
        let journal = MappingJournal(device: id, original: [], applied: [a, b], serviceCount: 2)
        XCTAssertTrue(journal.matchesApplied(states: [[b, a], [a, b]]))
        XCTAssertFalse(journal.matchesApplied(states: [[a, b]]))
        XCTAssertFalse(journal.matchesApplied(states: [[a, b], []]))
        XCTAssertFalse(journal.matchesApplied(states: []))
    }
    func testConfigurationRoundTripAndFutureVersionRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
        var value = Configuration(); value.preferredMode = .windows; value.selectedDevice = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        try Data("{\"schemaVersion\":999}".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "{\"schemaVersion\":999}")
    }
    func testLegacyConfigurationDefaultsToOriginalMappings() throws {
        let legacy = Data("{\"schemaVersion\":1,\"preferredMode\":\"unchanged\",\"onboardingComplete\":true}".utf8)
        var configuration = try JSONDecoder().decode(Configuration.self, from: legacy)
        XCTAssertEqual(configuration.selectedMappings, KeyboardMode.windows.mappings)
        configuration.enabledMappingSources = [0xe2, 0xe7]
        XCTAssertEqual(configuration.selectedMappings.map(\.source), [0xe2, 0xe7])
        configuration.enabledMappingSources = []
        XCTAssertTrue(configuration.selectedMappings.isEmpty)
    }
    func testDeviceProfilesKeepLegacySelectionAndAreIndependent() {
        let a = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        let b = DeviceIdentity(vendorID: 1, productID: 2, locationID: 4)
        var config = Configuration()
        config.selectedDevice = a; config.enabledMappingSources = [0xe2]
        XCTAssertEqual(config.rules(for: a).filter(\.enabled).map(\.source), [0xe2])
        config.setRules([KeyRule(source: 4, destination: 5)], for: b)
        XCTAssertEqual(config.rules(for: a).filter(\.enabled).map(\.source), [0xe2])
        XCTAssertEqual(config.rules(for: b), [KeyRule(source: 4, destination: 5)])
        config.selectedDevice = b
        XCTAssertEqual(config.selectedMappings, [KeyMapping(source: 4, destination: 5)])
    }
    func testGeneralSettingsDefaultsAndValidation() throws {
        let legacy = Data("{\"schemaVersion\":2,\"preferredMode\":\"unchanged\",\"onboardingComplete\":true}".utf8)
        var config = try JSONDecoder().decode(Configuration.self, from: legacy)
        XCTAssertEqual(config.effectiveDeviceRefreshInterval, 2)
        XCTAssertFalse(config.effectiveShowDockIcon)
        XCTAssertTrue(config.effectiveShowMenuBarIcon)
        config.deviceRefreshInterval = -1
        XCTAssertEqual(config.effectiveDeviceRefreshInterval, 2)
        config.deviceRefreshInterval = 0.5
        XCTAssertEqual(config.effectiveDeviceRefreshInterval, 0.5)
        config.showMenuBarIcon = false
        XCTAssertTrue(config.effectiveShowMenuBarIcon)
        config.showDockIcon = true
        XCTAssertFalse(config.effectiveShowMenuBarIcon)
    }
    private func device(id: String, builtIn: Bool?) -> KeyboardDevice {
        KeyboardDevice(id: id, name: "Keyboard", vendorID: 1, productID: 2, locationID: 3, transport: "USB", builtIn: builtIn)
    }
}

private final class MultiBackend: DeviceMappingBackend {
    var states: [[KeyMapping]] = [[], []]
    var writes = 0
    func read(device: DeviceIdentity) throws -> [KeyMapping] { states[0] }
    func readStates(device: DeviceIdentity) throws -> [[KeyMapping]] { states }
    func write(device: DeviceIdentity, mappings: [KeyMapping]) throws { writes += 1; states = states.map { _ in mappings } }
}

extension CoreTests {
    func testMultipleInterfacesAndPartialRecovery() throws {
        let backend = MultiBackend(), journal = TestJournal(), identity = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        let transaction = MappingTransaction(backend: backend, journal: journal)
        try transaction.apply(device: identity, mappings: KeyboardMode.windows.mappings)
        XCTAssertEqual(journal.value?.serviceCount, 2)
        backend.states[0] = [] // One interface has already reverted.
        try transaction.restore()
        XCTAssertEqual(backend.states, [[], []])
        XCTAssertNil(journal.value)
    }
    func testDifferentInterfaceMappingsAreNeverOverwritten() {
        let backend = MultiBackend(), journal = TestJournal(), identity = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        backend.states[1] = [KeyMapping(source: 1, destination: 2)]
        XCTAssertThrowsError(try MappingTransaction(backend: backend, journal: journal).apply(device: identity, mappings: KeyboardMode.windows.mappings))
        XCTAssertEqual(backend.writes, 0)
        XCTAssertNil(journal.value)
    }
}

private final class TestBackend: DeviceMappingBackend {
    var mappings: [KeyMapping] = []
    var writes = 0
    func read(device: DeviceIdentity) throws -> [KeyMapping] { mappings }
    func write(device: DeviceIdentity, mappings: [KeyMapping]) throws { self.mappings = mappings; writes += 1 }
}
private final class TestJournal: MappingJournalStore {
    var value: MappingJournal?
    var failSave = false
    func load() throws -> MappingJournal? { value }
    func save(_ journal: MappingJournal) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        value = journal
    }
    func remove() throws { value = nil }
}
extension CoreTests {
    func testTransactionPreservesUnrelatedMappingsAndRestores() throws {
        let backend = TestBackend(), journal = TestJournal(), identity = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        let existing = KeyMapping(source: 4, destination: 5)
        backend.mappings = [existing]
        let transaction = MappingTransaction(backend: backend, journal: journal)
        try transaction.apply(device: identity, mappings: KeyboardMode.windows.mappings)
        XCTAssertEqual(backend.mappings.count, 5)
        XCTAssertNotNil(journal.value)
        try transaction.restore()
        XCTAssertEqual(backend.mappings, [existing])
        XCTAssertNil(journal.value)
    }
    func testTransactionRefusesConflictsAndDoesNotOverwriteExternalChange() throws {
        let backend = TestBackend(), journal = TestJournal(), identity = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        let transaction = MappingTransaction(backend: backend, journal: journal)
        backend.mappings = [KeyMapping(source: 0xe2, destination: 4)]
        XCTAssertThrowsError(try transaction.apply(device: identity, mappings: KeyboardMode.windows.mappings))
        XCTAssertEqual(backend.writes, 0)
        backend.mappings = []
        try transaction.apply(device: identity, mappings: KeyboardMode.windows.mappings)
        backend.mappings = [KeyMapping(source: 4, destination: 5)]
        XCTAssertThrowsError(try transaction.restore())
        XCTAssertEqual(backend.writes, 1)
        XCTAssertNotNil(journal.value)
    }
    func testTransactionNeverWritesWithoutDurableJournal() {
        let backend = TestBackend(), journal = TestJournal(), identity = DeviceIdentity(vendorID: 1, productID: 2, locationID: 3)
        journal.failSave = true
        XCTAssertThrowsError(try MappingTransaction(backend: backend, journal: journal).apply(device: identity, mappings: KeyboardMode.windows.mappings))
        XCTAssertEqual(backend.writes, 0)
    }
}

extension CoreTests {
    func testJournalPersistsAcrossStoreInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mapping-journal.json")
        let saved = MappingJournal(device: DeviceIdentity(vendorID: 1, productID: 2, locationID: 3), original: [], applied: KeyboardMode.windows.mappings)
        try FileMappingJournalStore(url: url).save(saved)
        let recovered = FileMappingJournalStore(url: url)
        XCTAssertEqual(try recovered.load(), saved)
        try recovered.remove()
        XCTAssertNil(try recovered.load())
    }
}
