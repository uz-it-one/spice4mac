// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Spice4Mac", platforms: [.macOS("26.0")], products: [
    .executable(name: "Spice4MacApp", targets: ["SpiceMacApp"]),
    .executable(name: "spice4mac", targets: ["SpiceCLI"])
], targets: [
    .systemLibrary(name: "SpiceGLib", pkgConfig: "spice-client-glib-2.0"),
    .target(name: "CSpiceBridge", dependencies: ["SpiceGLib"], linkerSettings: [.linkedLibrary("pthread")]),
    .target(name: "ConnectionCore"),
    .target(name: "SessionCore", dependencies: ["ConnectionCore", "CSpiceBridge"]),
    .executableTarget(name: "SpiceMacApp", dependencies: ["SessionCore", "ConnectionCore"]),
    .executableTarget(name: "SpiceCLI", dependencies: ["ConnectionCore"]),
    .testTarget(name: "ConnectionCoreTests", dependencies: ["ConnectionCore"]),
    .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore", "CSpiceBridge"])
])
