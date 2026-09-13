// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NFLBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NFLBar", path: "Sources/NFLBar")
    ]
)
