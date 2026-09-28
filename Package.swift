// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DayStack",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DayStackCore", path: "Sources/DayStackCore"),
        .executableTarget(name: "DayStack", dependencies: ["DayStackCore"], path: "Sources/DayStack"),
        .executableTarget(name: "daystack-mcp", dependencies: ["DayStackCore"], path: "Sources/daystack-mcp"),
    ]
)
