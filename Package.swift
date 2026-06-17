// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TBTransfer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TBTransfer", targets: ["TBTransfer"]),
    ],
    targets: [
        .executableTarget(
            name: "TBTransfer",
            path: "Sources/TBTransfer",
            exclude: ["Resources/Info.plist"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "TBTransferTests",
            dependencies: ["TBTransfer"],
            path: "Tests/TBTransferTests"
        ),
    ]
)
