// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "NookKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
        .iOS("18.0"),
    ],
    products: [
        .library(name: "NookKit", targets: ["NookKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        // Nook Plus is opt-in. Reading feeds must keep working with no
        // account and no network, so nothing on the reader path may depend on
        // these types.
        .package(url: "https://github.com/nooker-app/nook-plus-protocol.git", exact: "0.2.2"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "NookKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "NookPlusProtocol", package: "nook-plus-protocol"),
                .product(name: "NookPlusServiceAPI", package: "nook-plus-protocol"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .copy("Readability.js"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "NookKitTests",
            dependencies: ["NookKit"]
        ),
    ]
)
