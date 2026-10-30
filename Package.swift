// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SideTapTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "sidetap", targets: ["SideTapCLI"])],
    targets: [
        .target(name: "SideTapCore", path: "SideTap/Core", exclude: ["AppStore.swift"]),
        .executableTarget(name: "SideTapCLI", dependencies: ["SideTapCore"], path: "CommandLine")
    ]
)
