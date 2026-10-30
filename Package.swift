// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TapDoneTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "tapdone", targets: ["TapDoneCLI"]),
               .executable(name: "sidetap", targets: ["TapDoneCLI"])],
    targets: [
        .target(name: "TapDoneCore", path: "TapDone/Core", exclude: ["AppStore.swift"]),
        .executableTarget(name: "TapDoneCLI", dependencies: ["TapDoneCore"], path: "CommandLine")
    ]
)
