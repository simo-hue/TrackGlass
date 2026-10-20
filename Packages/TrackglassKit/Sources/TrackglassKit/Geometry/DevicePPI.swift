// Pixel densities follow SPEC Appendix C; Apple references are in docs/DevicePPI.md.
public enum DevicePPI {
    public static func lookup(modelIdentifier: String) -> Double {
        if let device = DeviceCatalog.devices[modelIdentifier] { return device.ppi }
        return modelIdentifier.hasPrefix("iPad") ? 264 : 460
    }
}

public enum DeviceModelName {
    public static func marketingName(modelIdentifier: String) -> String {
        if let device = DeviceCatalog.devices[modelIdentifier] { return device.name }
        return modelIdentifier.hasPrefix("iPad") ? "iPad" : "iPhone"
    }
}

private enum DeviceCatalog {
    struct Device: Sendable {
        let name: String
        let ppi: Double
    }
    static let devices: [String: Device] = [
        "iPhone11,2": Device(name: "iPhone XS", ppi: 458),
        "iPhone11,4": Device(name: "iPhone XS Max", ppi: 458),
        "iPhone11,6": Device(name: "iPhone XS Max", ppi: 458),
        "iPhone11,8": Device(name: "iPhone XR", ppi: 326),
        "iPhone12,1": Device(name: "iPhone 11", ppi: 326),
        "iPhone12,3": Device(name: "iPhone 11 Pro", ppi: 458),
        "iPhone12,5": Device(name: "iPhone 11 Pro Max", ppi: 458),
        "iPhone12,8": Device(name: "iPhone SE (2nd generation)", ppi: 326),
        "iPhone13,1": Device(name: "iPhone 12 mini", ppi: 476),
        "iPhone13,2": Device(name: "iPhone 12", ppi: 460),
        "iPhone13,3": Device(name: "iPhone 12 Pro", ppi: 460),
        "iPhone13,4": Device(name: "iPhone 12 Pro Max", ppi: 458),
        "iPhone14,2": Device(name: "iPhone 13 Pro", ppi: 460),
        "iPhone14,3": Device(name: "iPhone 13 Pro Max", ppi: 458),
        "iPhone14,4": Device(name: "iPhone 13 mini", ppi: 476),
        "iPhone14,5": Device(name: "iPhone 13", ppi: 460),
        "iPhone14,6": Device(name: "iPhone SE (3rd generation)", ppi: 326),
        "iPhone14,7": Device(name: "iPhone 14", ppi: 460),
        "iPhone14,8": Device(name: "iPhone 14 Plus", ppi: 458),
        "iPhone15,2": Device(name: "iPhone 14 Pro", ppi: 460),
        "iPhone15,3": Device(name: "iPhone 14 Pro Max", ppi: 460),
        "iPhone15,4": Device(name: "iPhone 15", ppi: 460),
        "iPhone15,5": Device(name: "iPhone 15 Plus", ppi: 460),
        "iPhone16,1": Device(name: "iPhone 15 Pro", ppi: 460),
        "iPhone16,2": Device(name: "iPhone 15 Pro Max", ppi: 460),
        "iPhone17,1": Device(name: "iPhone 16 Pro", ppi: 460),
        "iPhone17,2": Device(name: "iPhone 16 Pro Max", ppi: 460),
        "iPhone17,3": Device(name: "iPhone 16", ppi: 460),
        "iPhone17,4": Device(name: "iPhone 16 Plus", ppi: 460),
        "iPhone17,5": Device(name: "iPhone 16e", ppi: 460),
        "iPhone18,1": Device(name: "iPhone 17 Pro", ppi: 460),
        "iPhone18,2": Device(name: "iPhone 17 Pro Max", ppi: 460),
        "iPhone18,3": Device(name: "iPhone 17", ppi: 460),
        "iPhone18,4": Device(name: "iPhone Air", ppi: 460),
        "iPad11,1": Device(name: "iPad mini (5th generation)", ppi: 326),
        "iPad11,2": Device(name: "iPad mini (5th generation)", ppi: 326),
        "iPad14,1": Device(name: "iPad mini (6th generation)", ppi: 326),
        "iPad14,2": Device(name: "iPad mini (6th generation)", ppi: 326),
        "iPad16,1": Device(name: "iPad mini (A17 Pro)", ppi: 326),
        "iPad16,2": Device(name: "iPad mini (A17 Pro)", ppi: 326),
        "iPad8,1": Device(name: "iPad Pro 11-inch (1st generation)", ppi: 264),
        "iPad8,2": Device(name: "iPad Pro 11-inch (1st generation)", ppi: 264),
        "iPad8,3": Device(name: "iPad Pro 11-inch (1st generation)", ppi: 264),
        "iPad8,4": Device(name: "iPad Pro 11-inch (1st generation)", ppi: 264),
        "iPad12,1": Device(name: "iPad (9th generation)", ppi: 264),
        "iPad12,2": Device(name: "iPad (9th generation)", ppi: 264),
        "iPad13,1": Device(name: "iPad Air (4th generation)", ppi: 264),
        "iPad13,2": Device(name: "iPad Air (4th generation)", ppi: 264)
    ]
}
