// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "androidtomac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "QuickShareEngine",
            targets: ["QuickShareEngine"]
        ),
        .executable(
            name: "AndroidToMacApp",
            targets: ["AndroidToMacApp"]
        ),
        .executable(
            name: "PrototypeHarness",
            targets: ["PrototypeHarness"]
        ),
        .executable(
            name: "TestRunner",
            targets: ["TestRunner"]
        )
    ],
    dependencies: [
        .package(path: "Packages/swift-protobuf")
    ],
    targets: [
        .target(
            name: "QuickShareEngine",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/QuickShareEngine"
        ),
        .executableTarget(
            name: "AndroidToMacApp",
            dependencies: ["QuickShareEngine"],
            path: "Sources/AndroidToMacApp"
        ),
        .executableTarget(
            name: "PrototypeHarness",
            dependencies: ["QuickShareEngine"],
            path: "Sources/PrototypeHarness"
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["QuickShareEngine"],
            path: "Sources/TestRunner"
        )
    ]
)
