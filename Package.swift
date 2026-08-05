// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YTComments",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "YTComments",
            path: "Sources/YTComments"
        ),
        .testTarget(
            name: "YTCommentsTests",
            dependencies: ["YTComments"],
            path: "Tests/YTCommentsTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
