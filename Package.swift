// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "foundation-tester",
    platforms: [
        .macOS("27.0"),  // Foundation Models のマルチモーダル(Attachment)が macOS 27+
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // @TestClass/@Test マクロの実装(コンパイル時のみ。成果物にはリンクされない)
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.1"..<"700.0.0"),
    ],
    targets: [
        // ステップモデル・AppDriverプロトコル・StepExecutor・スナップショット描画など
        // プラットフォーム非依存の中核(外部依存ゼロ)
        .target(
            name: "FTCore",
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
        // Android ドライバ(常駐ブリッジ。AppDriver の別実装)
        .target(
            name: "FTAndroid",
            dependencies: ["FTCore", "FTBridgeClient"],
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
                "FTDSL",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swift5Mode
        ),
        // @TestClass/@Test マクロ実装(swift-syntax はこのターゲットに閉じる)
        .macro(
            name: "FTDSLMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: swift5Mode
        ),
        // Shirates 風 Swift テスト DSL(シナリオ記述用のユーザー向けライブラリ)
        .target(
            name: "FTDSL",
            dependencies: ["FTCore", "FTDSLMacros"],
            swiftSettings: swift5Mode
        ),
        // ftester-scenarios の CLI 実装(list/run・NDJSON イベント出力)
        .target(
            name: "FTScenarioRunner",
            dependencies: [
                "FTDSL",
                "FTCore",
                "FTBridgeClient",
                "FTAgent",
                "FTAndroid",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swift5Mode
        ),
        // テストプロジェクト(Projects/<name>/Scenarios/)のシナリオ実行ターゲット。
        // _disabled/ は退避場所(コンパイル対象外。並列デモ等をここに置く)
        // === ftester projects begin(ftester project create/sync が自動生成。手編集禁止)===
        .executableTarget(
            name: "ftester-scenarios-SampleApp",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/SampleApp/Scenarios",
            exclude: ["_disabled"],
            swiftSettings: swift5Mode
        ),
        .executableTarget(
            name: "ftester-scenarios-project1",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/project1/Scenarios",
            exclude: ["_disabled"],
            swiftSettings: swift5Mode
        ),
        // === ftester projects end ===
        // headless iOS シミュレータ画面キャプチャ(ObjC単体・CoreSimulator/SimulatorKitはdlopen)
        .executableTarget(
            name: "ftester-simstream",
            linkerSettings: [
                .linkedFramework("Foundation"), .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"), .linkedFramework("IOSurface"),
                .linkedFramework("QuartzCore"), .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"), .linkedFramework("VideoToolbox"),
            ]
        ),
        // Android実機/エミュレータ画面ストリーミング(adb screenrecord H.264 -> VideoToolboxデコード)
        .executableTarget(
            name: "ftester-androidstream",
            linkerSettings: [
                .linkedFramework("Foundation"), .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"), .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "FTCoreTests",
            dependencies: ["FTCore"],
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "FTBridgeClientTests",
            dependencies: ["FTBridgeClient", "FTCore"],
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "FTAndroidTests",
            dependencies: ["FTAndroid", "FTCore"],
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "FTDSLTests",
            // swift-syntax 2 プロダクトは swiftbuild バックエンド対策。FTDSLTests→FTDSL→FTDSLMacros
            // の依存で、swiftbuild はマクロ(.macro)のオブジェクトをテストバンドルに誤って取り込むが
            // swift-syntax をリンクしないため SwiftSyntax 系シンボルが undefined になる。ここで
            // リンクして解決する(native バックエンドは取り込まないので未使用リンクで無害)。
            // swiftbuild が直ったら削除可
            dependencies: [
                "FTDSL",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "FTDSLMacrosTests",
            dependencies: [
                "FTDSLMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: swift5Mode
        ),
    ]
)
