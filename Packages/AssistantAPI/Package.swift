// swift-tools-version:5.10
// The API client, generated at build time from the API's contract (Sources/AssistantAPI/openapi.json,
// copied from the API repo by ../../update-api.sh).
import PackageDescription

let package = Package(
    name: "AssistantAPI",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AssistantAPI", targets: ["AssistantAPI"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", .upToNextMinor(from: "1.10.4")),
        .package(url: "https://github.com/apple/swift-openapi-runtime", .upToNextMinor(from: "1.10.1")),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", .upToNextMinor(from: "1.2.0")),
    ],
    targets: [
        .target(
            name: "AssistantAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
    ]
)
