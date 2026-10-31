import Foundation
import IOKit

// Dumps the built-in trackpad's acceleration registry values as JSON (SPEC §6.6 "Where the numbers come from",
// §6.8 G-SCR). A missing required key fails the dump; optional keys are written only when found.
private let requiredKeys = [
    "HIDAccelCurves",
    "HIDPointerResolution",
    "HIDPointerReportRate"
]

private let optionalKeys = [
    "HIDScrollAccelCurves",
    "HIDPointerAccelerationTable",
    // Scroll-specific resolution, rate and settings: the G-SCR curve units depend on them (SPEC §6.8).
    "HIDScrollResolution",
    "HIDScrollResolutionX",
    "HIDScrollResolutionY",
    "HIDScrollReportRate",
    "HIDTrackpadScrollAcceleration",
    "HIDTrackpadAcceleration",
    "HIDScrollAccelerationType",
    // The settings the HID event system applied to this service.
    "HIDEventServiceProperties"
]

private let usageText = """
usage: tgaccel

Prints the built-in trackpad's pointer and scroll acceleration registry values as JSON on standard output.
A key that is not on the trackpad service or below it is looked up on the service's parents;
"tgaccelKeySources" records where each key was found. Takes no arguments.
Exit status: 0 dumped, 1 no built-in trackpad or a required key missing, 2 usage.

"""

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

/// Where a key was found: on the trackpad service or one of its children, or (fallback) on one of its parents.
private enum KeySource: String {
    case serviceOrChildren
    case parents
}

private func value(for key: String, on service: io_service_t) -> (value: Any, source: KeySource)? {
    let searches: [(options: IOOptionBits, source: KeySource)] = [
        (IOOptionBits(kIORegistryIterateRecursively), .serviceOrChildren),
        (IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents), .parents)
    ]
    for search in searches {
        guard let property = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
            kCFAllocatorDefault, search.options), let value = jsonValue(property) else { continue }
        return (value, search.source)
    }
    return nil
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
        var sources: [String: String] = [:]
        for key in requiredKeys {
            guard let found = value(for: key, on: service) else { throw AccelDumpError.missingProperty(key) }
            result[key] = found.value
            sources[key] = found.source.rawValue
        }
        // An optional value JSON cannot represent (e.g. a non-finite number) is left out instead of failing the dump.
        for key in optionalKeys {
            guard let found = value(for: key, on: service),
                  JSONSerialization.isValidJSONObject([key: found.value] as [String: Any]) else { continue }
            result[key] = found.value
            sources[key] = found.source.rawValue
        }
        result["HIDPointerAccelerationTableEncoding"] = "lowercase hexadecimal bytes"
        result["tgaccelKeySources"] = sources
        return result
    }
    throw AccelDumpError.noBuiltInTrackpad
}

if CommandLine.arguments.count > 1 {
    let argument = CommandLine.arguments[1]
    if argument != "--help" && argument != "-h" { fputs("tgaccel: unexpected argument '\(argument)'\n", stderr) }
    fputs(usageText, stderr)
    exit(2)
}

do {
    let properties = try readTrackpadProperties()
    guard JSONSerialization.isValidJSONObject(properties) else { throw AccelDumpError.invalidJSON }
    let data = try JSONSerialization.data(withJSONObject: properties, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("tgaccel: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
