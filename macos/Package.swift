// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuantAssistant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuantAssistant",
            path: "Sources/QuantAssistant",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "QuantAssistantTests",
            dependencies: ["QuantAssistant"],
            path: "Tests/QuantAssistantTests"
        ),
    ]
)
