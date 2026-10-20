// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackglassKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TrackglassKit", targets: ["TrackglassKit"])],
    targets: [
        .target(name: "TrackglassKit", swiftSettings: [.unsafeFlags(["-warnings-as-errors", "-strict-concurrency=complete"])]),
        .testTarget(name: "TrackglassKitTests", dependencies: ["TrackglassKit"], swiftSettings: [.unsafeFlags(["-warnings-as-errors", "-strict-concurrency=complete"])])
    ],
    swiftLanguageModes: [.v6]
)
