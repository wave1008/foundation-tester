// ブリッジの HTTP ルート表が変わったことを検出し、版数の引き上げを促す。
//
// 事故の形(実害2回): エンドポイントを足したのに版数を上げず、稼働中の旧ブリッジが
// 「版一致」として再利用され、新エンドポイントが 404 のまま緑になる。
// 版数は片側だけ上げても検出できるが(iOS = BridgeAPI.bridgeProtocolVersion は
// ホスト・in-app・XCUITest ランナーの共有定数 / Android = AndroidBridgeVersionSyncTests)、
// 「そもそも上げ忘れた」は今まで人間の規律だけが頼りだった。
//
// **このテストの限界**: ルート表の変更を検出して版数を上げるよう促すだけで、版数を上げること
// 自体は強制できない(ここの期待値だけ更新して版数を据え置くことは手続き上できてしまう)。
// また、ルートが同じままハンドラの挙動だけ変えた場合は検出できない。それでも、無音で緑になる
// 状態からは変わる。

import XCTest
import FTCore

final class BridgeRouteContractTests: XCTestCase {

    // 期待するルート表。**変更したら対応する版数を必ず上げること**:
    //   in-app / XCUITest ランナー → Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion
    //   Android                    → AndroidRunner/build.sh の VERSION_CODE と
    //                                Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode
    // 3実装でルートが異なるのは仕様(in-app は同一プロセスしか見えないので /drag・/appswitcher・
    // /home を持たず、/locale は Android だけ)。
    private static let inAppRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /press", "POST /pressEnter", "POST /session",
        "POST /swipe", "POST /tap", "POST /terminate", "POST /type",
    ]

    private static let xcuiTestRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appswitcher", "POST /drag", "POST /home",
        "POST /press", "POST /pressEnter", "POST /session",
        "POST /swipe", "POST /tap", "POST /terminate", "POST /type",
    ]

    private static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /locale", "POST /press", "POST /pressEnter",
        "POST /session", "POST /swipe", "POST /tap",
        "POST /terminate", "POST /type",
    ]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    func testInAppBridgeRoutesUnchanged() throws {
        try assertRoutes(
            file: "InAppBridge/Sources/InAppBridge.swift",
            pattern: swiftRoutePattern,
            expected: Self.inAppRoutes,
            versionHint: "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
                + "(現在 \(BridgeAPI.bridgeProtocolVersion))")
    }

    func testXCUITestRunnerRoutesUnchanged() throws {
        try assertRoutes(
            file: "Runner/FTesterRunnerUITests/BridgeRouter.swift",
            pattern: swiftRoutePattern,
            expected: Self.xcuiTestRoutes,
            versionHint: "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
                + "(現在 \(BridgeAPI.bridgeProtocolVersion))")
    }

    func testAndroidBridgeRoutesUnchanged() throws {
        try assertRoutes(
            file: "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java",
            pattern: javaRoutePattern,
            expected: Self.androidRoutes,
            versionHint: "AndroidRunner/build.sh の VERSION_CODE と "
                + "Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode")
    }

    // MARK: - 抽出

    /// Swift 側: `case ("GET", "/status")` → `GET /status`
    private let swiftRoutePattern = #"case \("(GET|POST)", "(/[A-Za-z]+)"\)"#
    /// Java 側: `case "GET /status":` → `GET /status`
    private let javaRoutePattern = #"case "(GET|POST) (/[A-Za-z]+)":"#

    private func assertRoutes(file: String, pattern: String,
                              expected: Set<String>, versionHint: String) throws {
        let url = repoRoot.appendingPathComponent(file)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(file) を読めません")
        }
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: Set<String> = []
        for match in regex.matches(in: source, range: range) {
            guard let method = Range(match.range(at: 1), in: source),
                  let path = Range(match.range(at: 2), in: source) else { continue }
            found.insert("\(source[method]) \(source[path])")
        }

        XCTAssertFalse(found.isEmpty,
                       "\(file) からルートを1件も抽出できません"
                       + "(ルーティングの書き方を変えたなら、このテストの抽出パターンも直すこと)")
        XCTAssertEqual(found, expected,
                       "\(file) のルート表が変わりました"
                       + "(追加: \(found.subtracting(expected).sorted()) / "
                       + "削除: \(expected.subtracting(found).sorted()))。"
                       + "**\(versionHint) を上げてから**、このテストの期待値を更新すること。"
                       + "上げないと稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる")
    }
}
