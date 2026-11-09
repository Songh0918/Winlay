import Foundation
import IOKit.hid

final class KeyboardDeviceManager {
    private let manager: IOHIDManager
    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
    func devices() -> [KeyboardDevice] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { device in
            func number(_ key: String) -> Int? { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue }
            func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
            let vendor = number(kIOHIDVendorIDKey), product = number(kIOHIDProductIDKey), location = number(kIOHIDLocationIDKey)
            let service = IOHIDDeviceGetService(device)
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            let builtIn = (IOHIDDeviceGetProperty(device, "Built-In" as CFString) as? NSNumber)?.boolValue
            return KeyboardDevice(id: String(registryID), name: string(kIOHIDProductKey) ?? "未命名键盘", vendorID: vendor, productID: product, locationID: location, transport: string(kIOHIDTransportKey) ?? "未知", builtIn: builtIn)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
