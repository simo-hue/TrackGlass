import Foundation
import IOKit

private let requestedKeys = [
    "HIDAccelCurves",
    "HIDPointerResolution",
    "HIDPointerReportRate",
    "HIDScrollAccelCurves",
    "HIDPointerAccelerationTable"
]

private enum AccelDumpError: Error, CustomStringConvertible {
    case noBuiltInTrackpad
    case missingProperty(String)
    case invalidJSON

    var description: String {
        switch self {
        case .noBuiltInTrackpad: "No built-in Apple multitouch trackpad service was found."
        case .missingProperty(let key): "The built-in trackpad does not expose \(key)."
        case .invalidJSON: "The registry properties could not be represented as JSON."
        }
    }
}

private func isBuiltIn(_ service: io_service_t) -> Bool {
    guard let value = IORegistryEntryCreateCFProperty(service, "Built-In" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
        return false
    }
    return (value as? NSNumber)?.boolValue ?? false
}

private func value(for key: String, on service: io_service_t) -> Any? {
    guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
        kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) else { return nil }
    return jsonValue(value)
}

private func jsonValue(_ value: CFTypeRef) -> Any? {
    if CFGetTypeID(value) == CFDataGetTypeID() {
        guard let data = value as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    if let dictionary = value as? [String: Any] {
        var converted: [String: Any] = [:]
        for (key, item) in dictionary {
            guard let convertedItem = jsonValue(item as CFTypeRef) else { continue }
            converted[key] = convertedItem
        }
        return converted
    }
    if let array = value as? [Any] {
        return array.compactMap { item -> Any? in
            jsonValue(item as CFTypeRef)
        }
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as? NSNumber)?.boolValue }
    if let number = value as? NSNumber { return number }
    if let string = value as? String { return string }
    return nil
}

private func readTrackpadProperties() throws -> [String: Any] {
    guard let matching = IOServiceMatching("AppleMultitouchTrackpadHIDEventDriver") else {
        throw AccelDumpError.noBuiltInTrackpad
    }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        throw AccelDumpError.noBuiltInTrackpad
    }
    defer { IOObjectRelease(iterator) }
    while true {
        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else { break }
        defer { IOObjectRelease(service) }
        guard isBuiltIn(service) else { continue }
        var result: [String: Any] = [:]
        for key in requestedKeys {
            guard let property = value(for: key, on: service) else {
                if key == "HIDScrollAccelCurves" || key == "HIDPointerAccelerationTable" { continue }
                throw AccelDumpError.missingProperty(key)
            }
            result[key] = property
        }
        result["HIDPointerAccelerationTableEncoding"] = "lowercase hexadecimal bytes"
        return result
    }
    throw AccelDumpError.noBuiltInTrackpad
}

do {
    guard CommandLine.arguments.count == 1 else { throw AccelDumpError.invalidJSON }
    let properties = try readTrackpadProperties()
    guard JSONSerialization.isValidJSONObject(properties) else { throw AccelDumpError.invalidJSON }
    let data = try JSONSerialization.data(withJSONObject: properties, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("tgaccel: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
