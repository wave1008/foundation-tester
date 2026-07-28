// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "foundation-tester",
    platforms: [
        // FoundationModels 本体(テキスト生成・Generable)は macOS 26+。
        // マルチモーダル(Attachment)だけが macOS 27+ なので、その呼び出しは
        // #available で分岐する(FTAgent/OcclusionVerifier.swift・ReplayAssist.swift)。
        // ここを 27 に上げると macOS 26 でビルドすら通らなくなる。
        .macOS("26.0"),
    ],
    // 外部パッケージ(ftester init が生成する受け手の Package.swift)が依存する公開 product。
    // 受け手のシナリオターゲットは .product(name: "FTScenarioRunner"/"FTDSL", package: "foundation-tester")
    // を dependencies に持つ(対向: Sources/FTCore/PackageManifestEditor.swift の external モード)。
    // FTScenarioRunner が FTCore/FTBridgeClient/FTAgent/FTAndroid を、FTDSL が FTDSLMacros を
    // 推移的に引くため、公開が要るのはこの3つだけ。ftester は CLI ツール本体。
    products: [
        .executable(name: "ftester", targets: ["ftester"]),
        .library(name: "FTScenarioRunner", targets: ["FTScenarioRunner"]),
        .library(name: "FTDSL", targets: ["FTDSL"]),
        .library(name: "FTCore", targets: ["FTCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // @TestClass/@Test マクロの実装(コンパイル時のみ。成果物にはリンクされない)
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.1"..<"700.0.0"),
        // エミュレータ EmulatorController gRPC クライアント(FTEmulatorGrpc)。
        // 3 リポジトリで1セット(core / NIO トランスポート / protobuf ランタイム)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
    ],
    targets: [
        // ステップモデル・AppDriverプロトコル・StepExecutor・スナップショット描画など
        // プラットフォーム非依存の中核(外部依存ゼロ)
        .target(
            name: "FTCore",
            swiftSettings: swift5Mode
        ),
        // CoreSimulator 直叩きシム(ObjC・dlopen。SimulatorCatalog の simctl 高速化用)
        .target(
            name: "FTCoreSimShim"
        ),
        // XCUITestランナー(ブリッジ)へのHTTPクライアントと起動管理
        .target(
            name: "FTBridgeClient",
            dependencies: ["FTCore", "FTCoreSimShim"],
            swiftSettings: swift5Mode
        ),
        // FoundationModels 補助層(自己修復・失敗トリアージ・シナリオ命名)
        .target(
            name: "FTAgent",
            dependencies: ["FTCore"],
            swiftSettings: swift5Mode
        ),
        // エミュレータ EmulatorController gRPC クライアント(Generated/ は protoc 生成コードの
        // vendored コピー。proto の正は third_party/emulator-proto/。再生成手順は同ディレクトリの
        // README を参照。受け手ビルドに protoc を要求しないため生成物をコミットする)
        .target(
            name: "FTEmulatorGrpc",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        // Android ドライバ(常駐ブリッジ。AppDriver の別実装)
        .target(
            name: "FTAndroid",
            dependencies: ["FTCore", "FTBridgeClient", "FTEmulatorGrpc"],
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
            name: "ftester-scenarios-E2E",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/E2E/Scenarios",
            exclude: ["_disabled"],
            swiftSettings: swift5Mode
        ),
        .executableTarget(
            name: "ftester-scenarios-E2E-Android",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/E2E-Android/Scenarios",
            exclude: ["_disabled"],
            swiftSettings: swift5Mode
        ),
        .executableTarget(
            name: "ftester-scenarios-E2E-Flutter",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/E2E-Flutter/Scenarios",
            exclude: ["_disabled"],
            swiftSettings: swift5Mode
        ),
        .executableTarget(
            name: "ftester-scenarios-E2E-iOS",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/E2E-iOS/Scenarios",
            exclude: ["_disabled"],
            swiftSettings: swift5Mode
        ),
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
        .executableTarget(
            name: "ftester-scenarios-sut-ec-mobile",
            dependencies: ["FTScenarioRunner", "FTDSL"],
            path: "Projects/sut-ec-mobile/Scenarios",
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
        // 実機(iOS/Android)画面ストリーミング(スクリーンショットのポーリング -> MJPEG)。
        // simstream(シミュレータ専用)・androidstream(静止画面でフレームが出ない)の実機向け代替
        .executableTarget(
            name: "ftester-devicepoll",
            linkerSettings: [
                .linkedFramework("Foundation"), .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"), .linkedFramework("UniformTypeIdentifiers"),
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
            name: "FTAgentTests",
            dependencies: ["FTAgent", "FTCore"],
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "FTAndroidTests",
            dependencies: ["FTAndroid", "FTCore", "FTBridgeClient"],
            swiftSettings: swift5Mode
        ),
        // ftester-mcp は executableTarget だが @testable import 可能(モジュール名は c99name の
        // ftester_mcp)。toolDefinitions のスキーマ宣言と drivers キャッシュキーの純関数のみ対象
        .testTarget(
            name: "FTesterMCPTests",
            dependencies: ["ftester-mcp"],
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
