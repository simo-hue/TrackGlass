import Foundation
import IOKit
import OSLog
import TrackglassEngine

enum PointerAccelerationProvider {
    private static let logger = Logger(subsystem: "app.trackglass.mac", category: "prefs")   // §6.10: net, engine, inject, prefs
    private static let registryKeys = ["HIDAccelCurves", "HIDPointerResolution", "HIDPointerReportRate"]

    static func make(settings: TrackpadSettings) -> PointerAccelerator {
        if let liveData = readLiveRegistry(), let accelerator = makeAccelerator(liveData, settings: settings) {
            logger.info("using live trackpad acceleration curves")
            return accelerator
        }
        if let bundleURL = Bundle.main.url(forResource: "DefaultAccelCurves", withExtension: "json"),
           let bundleData = try? Data(contentsOf: bundleURL),
           let accelerator = makeAccelerator(bundleData, settings: settings) {
            logger.info("using bundled default trackpad acceleration curves")
            return accelerator
        }
        logger.error("live and bundled trackpad acceleration data unavailable; using specification fallback")
        return .fallback(trackingSpeed: settings.trackingSpeed)
    }

    static func makeScroll(settings: TrackpadSettings) -> any AccelerationModel {
        let bundled = Bundle.main.url(forResource: "DefaultAccelCurves", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        for data in [readLiveRegistry(), bundled].compactMap({ $0 }) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resolution = (root["HIDPointerResolution"] as? NSNumber)?.doubleValue,
                  let rate = (root["HIDPointerReportRate"] as? NSNumber)?.doubleValue,
                  let curves = try? ParametricAccelerationCurve.decodeScrollCurves(from: data),
                  let accelerator = try? ScrollAccelerator(curves: curves, resolution: resolution / 65_536,
                      reportRate: rate, trackingSpeed: settings.trackingSpeed) else { continue }
            logger.info("using Apple parametric scroll acceleration")
            return accelerator
        }
        logger.notice("scroll curves unavailable; using specification fallback")
        return ScrollFallbackAcceleration()
    }

    private static func makeAccelerator(_ data: Data, settings: TrackpadSettings) -> PointerAccelerator? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResolution = (root["HIDPointerResolution"] as? NSNumber)?.doubleValue,
              let reportRate = (root["HIDPointerReportRate"] as? NSNumber)?.doubleValue else { return nil }
        return try? PointerAccelerator(registryJSON: data, resolution: rawResolution / 65_536,
                                       reportRate: reportRate, trackingSpeed: settings.trackingSpeed)
    }

    private static func readLiveRegistry() -> Data? {
        guard let matching = IOServiceMatching("AppleMultitouchTrackpadHIDEventDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var firstAvailable: Data?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }
            guard let data = registryData(from: service) else { continue }
            let builtIn = (IORegistryEntryCreateCFProperty(service, "Built-In" as CFString,
                                                            kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
            if builtIn { return data }
            if firstAvailable == nil { firstAvailable = data }
        }
        return firstAvailable
    }

    private static func registryData(from service: io_service_t) -> Data? {
        var values: [String: Any] = [:]
        for key in registryKeys {
            guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) else { return nil }
            values[key] = value
        }
        if let scroll = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "HIDScrollAccelCurves" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) {
            values["HIDScrollAccelCurves"] = scroll
        }
        guard JSONSerialization.isValidJSONObject(values) else { return nil }
        return try? JSONSerialization.data(withJSONObject: values)
    }
}
