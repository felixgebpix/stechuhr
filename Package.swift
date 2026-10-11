// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Stechuhr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Stechuhr", targets: ["Stechuhr"]),
        .executable(name: "stechuhr-hook", targets: ["StechuhrHook"]),
    ],
    targets: [
        .target(
            name: "StechuhrCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Stechuhr",
            dependencies: ["StechuhrCore"]
        ),
        .executableTarget(
            name: "StechuhrHook",
            path: "Sources/StechuhrHook"
        ),
        .testTarget(
            name: "StechuhrCoreTests",
            dependencies: ["StechuhrCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
