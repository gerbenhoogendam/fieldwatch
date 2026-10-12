// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fieldwatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fieldwatch", targets: ["Fieldwatch"]),
        .library(name: "FieldwatchCore", targets: ["FieldwatchCore"]),
    ],
    targets: [
        .target(
            name: "FieldwatchCore",
            resources: [.copy("Resources/radiodb.bin"), .copy("Resources/fieldwatch-signatures-v2.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Fieldwatch",
            dependencies: ["FieldwatchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Embed Info.plist so `swift run` / Xcode launches carry the Bluetooth and Location usage strings.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])]
        ),
        .testTarget(
            name: "FieldwatchCoreTests",
            dependencies: ["FieldwatchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
