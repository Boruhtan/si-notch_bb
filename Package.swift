// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "si-notch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "si-notch", targets: ["SINotch"]),
        .executable(name: "si-notchctl", targets: ["NotchCLI"]),
        .library(name: "SINotchCore", targets: ["SINotchCore"]),
        .library(name: "SINotchTransport", targets: ["SINotchTransport"])
    ],
    targets: [
        .target(name: "SINotchCore"),
        .target(name: "SINotchTransport"),
        .executableTarget(name: "SINotch", dependencies: ["SINotchCore", "SINotchTransport"], resources: [.process("Resources")]),
        .executableTarget(name: "NotchCLI", dependencies: ["SINotchCore", "SINotchTransport"]),
        .testTarget(name: "SINotchCoreTests", dependencies: ["SINotchCore"]),
        .testTarget(name: "SINotchAppTests", dependencies: ["SINotch"]),
        .testTarget(name: "SINotchTransportTests", dependencies: ["SINotchTransport"])
    ],
    swiftLanguageModes: [.v5]
)
