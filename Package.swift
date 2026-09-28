// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DayStack",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DayStack", path: "Sources/DayStack")
    ]
)
