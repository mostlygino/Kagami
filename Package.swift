// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Kagami",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "KagamiApp", targets: ["KagamiApp"]),
        .executable(name: "kagami-cli", targets: ["KagamiCLI"]),
    ],
    targets: [
        .target(name: "KagamiCore", path: "Sources/KagamiCore"),
        .executableTarget(name: "KagamiApp", dependencies: ["KagamiCore"], path: "Sources/KagamiApp"),
        .executableTarget(name: "KagamiCLI", dependencies: ["KagamiCore"], path: "Sources/KagamiCLI"),
        .testTarget(name: "KagamiTests", dependencies: ["KagamiCore"], path: "Tests/KagamiTests",
                    resources: [.copy("fixture.pcap"), .copy("anatomy.pcap"), .copy("flows.pcap"), .copy("flows.nfcapd")]),
    ],
    swiftLanguageModes: [.v5]
)
