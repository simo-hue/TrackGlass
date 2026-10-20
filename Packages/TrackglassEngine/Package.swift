// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackglassEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TrackglassEngine", targets: ["TrackglassEngine"])],
    dependencies: [.package(path: "../TrackglassKit")],
    targets: [
        .target(name: "TrackglassEngine", dependencies: ["TrackglassKit"], swiftSettings: [.unsafeFlags(["-warnings-as-errors", "-strict-concurrency=complete"])]),
        .testTarget(name: "EngineTests", dependencies: ["TrackglassEngine"], swiftSettings: [.unsafeFlags(["-warnings-as-errors", "-strict-concurrency=complete"])])
    ],
    swiftLanguageModes: [.v6]
)
