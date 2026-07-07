// swift-tools-version: 6.0
import PackageDescription

let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "foundation-tester",
    platforms: [
        .macOS("27.0"),  // Foundation Models のマルチモーダル(Attachment)が macOS 27+
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    ],
    targets: [
        // Flow DSL・AppDriverプロトコル・スナップショット描画などプラットフォーム非依存の中核
        .target(
            name: "FTCore",
            dependencies: ["Yams"],
            swiftSettings: swift5Mode
        ),
        // XCUITestランナー(ブリッジ)へのHTTPクライアントと起動管理
        .target(
            name: "FTBridgeClient",
            dependencies: ["FTCore"],
            swiftSettings: swift5Mode
        ),
        // FoundationModels エージェント層(Explorer/Verifier/Triager)
        .target(
            name: "FTAgent",
            dependencies: ["FTCore"],
            swiftSettings: swift5Mode
        ),
        // Android ドライバ(adb 直叩き。AppDriver の別実装)
        .target(
            name: "FTAndroid",
            dependencies: ["FTCore"],
            swiftSettings: swift5Mode
        ),
        // GUI(SwiftUI macOS アプリ)。フロー実行とライブ操作
        .executableTarget(
            name: "ftester-gui",
            dependencies: [
                "FTCore",
                "FTBridgeClient",
                "FTAgent",
                "FTAndroid",
            ],
            swiftSettings: swift5Mode
        ),
        // MCP サーバ(stdio)。Claude Code 等のエージェントからブリッジ操作・フロー実行を使えるようにする
        .executableTarget(
            name: "ftester-mcp",
            dependencies: [
                "FTCore",
                "FTBridgeClient",
                "FTAgent",
                "FTAndroid",
            ],
            swiftSettings: swift5Mode
        ),
        .executableTarget(
            name: "ftester",
            dependencies: [
                "FTCore",
                "FTBridgeClient",
                "FTAgent",
                "FTAndroid",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swift5Mode
        ),
    ]
)
