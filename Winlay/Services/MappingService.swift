import Foundation

struct HIDMappingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Operates on matching HID event services for one identified device.
struct HIDMappingBackend: DeviceMappingBackend {
    private let srcKey = "HIDKeyboardModifierMappingSrc"
    private let dstKey = "HIDKeyboardModifierMappingDst"
    private func invoke(_ arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments; process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HIDMappingError(message: "hidutil 执行失败：\(String(decoding: errorData, as: UTF8.self))") }
        return String(decoding: data, as: UTF8.self)
    }
    private func matching(_ device: DeviceIdentity) throws -> String {
        let value: [String: Int] = ["VendorID": device.vendorID, "ProductID": device.productID, "LocationID": device.locationID, "PrimaryUsagePage": 1, "PrimaryUsage": 6]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func checkedMatching(_ device: DeviceIdentity) throws -> (String, Set<UInt64>) {
        let match = try matching(device)
        let output = try invoke(["list", "--ndjson", "--matching", match])
        let services = try output.split(whereSeparator: \.isNewline).compactMap { line -> [String: Any]? in
            guard let data = String(line).data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HIDMappingError(message: "无法解析 HID 服务信息。") }
            return object["type"] as? String == "service" ? object : nil
        }
        let ids = services.compactMap { ($0["IORegistryEntryID"] as? NSNumber)?.uint64Value }
        guard !services.isEmpty, ids.count == services.count, Set(ids).count == ids.count,
              services.allSatisfy({ service in
                  guard let transport = service["Transport"] as? String else { return false }
                  return (service["Built-In"] as? Bool) == true || ["usb", "bluetooth"].contains(transport.lowercased())
              }) else {
            throw HIDMappingError(message: "无法确认匹配的键盘服务，已停止操作。")
        }
        return (match, Set(ids))
    }
    func read(device: DeviceIdentity) throws -> [KeyMapping] {
        let states = try readStates(device: device)
        guard let first = states.first, states.allSatisfy({ $0 == first }) else { throw HIDMappingError(message: "键盘接口的映射不一致。") }
        return first
    }
    func readStates(device: DeviceIdentity) throws -> [[KeyMapping]] {
        let (match, ids) = try checkedMatching(device)
        let output = try invoke(["property", "--matching", match, "--get", "UserKeyMapping"])
        let ns = output as NSString
        let headers = try NSRegularExpression(pattern: "(?m)^[ \\t]*([0-9a-fA-F]+)[ \\t]+UserKeyMapping[ \\t]+").matches(in: output, range: NSRange(location: 0, length: ns.length))
        var values: [UInt64: [KeyMapping]] = [:]
        for (index, header) in headers.enumerated() {
            guard let id = UInt64(ns.substring(with: header.range(at: 1)), radix: 16), ids.contains(id), values[id] == nil else { throw HIDMappingError(message: "设备映射服务标识异常。") }
            let start = NSMaxRange(header.range)
            let end = index + 1 < headers.count ? headers[index + 1].range.location : ns.length
            values[id] = try parseMapping(ns.substring(with: NSRange(location: start, length: end - start)))
        }
        guard Set(values.keys) == ids else { throw HIDMappingError(message: "无法读取全部键盘接口的映射。") }
        return ids.sorted().map { values[$0]! }
    }
    private func parseMapping(_ raw: String) throws -> [KeyMapping] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "(null)" || value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") == "()" { return [] }
        let regex = try NSRegularExpression(pattern: "\\{([^{}]*)\\}")
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { throw HIDMappingError(message: "无法解析已有映射，拒绝修改。") }
        let remaining = regex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: ns.length), withTemplate: "").filter { !$0.isWhitespace && $0 != "(" && $0 != ")" && $0 != "," }
        guard remaining.isEmpty else { throw HIDMappingError(message: "已有映射包含不支持的数据，拒绝修改。") }
        return try matches.map { match in
            let body = ns.substring(with: match.range(at: 1))
            let fields = body.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard fields.count == 2 else { throw HIDMappingError(message: "已有映射字段异常。") }
            var parsed: [String: UInt64] = [:]
            for field in fields {
                let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard pair.count == 2, (pair[0] == srcKey || pair[0] == dstKey), let number = UInt64(pair[1]), parsed[pair[0]] == nil else { throw HIDMappingError(message: "无法读取已有映射，拒绝修改。") }
                parsed[pair[0]] = number
            }
            guard let source = parsed[srcKey], let destination = parsed[dstKey] else { throw HIDMappingError(message: "映射字段不完整。") }
            func usage(_ n: UInt64) -> UInt64 { (n & 0xffff_ffff_0000_0000) == 0x0000_0007_0000_0000 ? n & 0xffff_ffff : n }
            return KeyMapping(source: usage(source), destination: usage(destination))
        }
    }
    func write(device: DeviceIdentity, mappings: [KeyMapping]) throws {
        let (match, _) = try checkedMatching(device)
        func full(_ usage: UInt64) -> UInt64 { usage <= 0xffff_ffff ? 0x700000000 | usage : usage }
        let entries = mappings.map { [srcKey: full($0.source), dstKey: full($0.destination)] }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["UserKeyMapping": entries]), as: UTF8.self)
        _ = try invoke(["property", "--matching", match, "--set", payload])
    }
}
