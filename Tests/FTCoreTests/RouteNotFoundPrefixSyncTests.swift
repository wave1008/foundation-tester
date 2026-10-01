// 3つのブリッジが未知のルートに返す 404 の本文("not found: METHOD PATH")と、
// `DriverError.isEngineIncapable` が見る接頭辞 "not found:" の同期。
// 404 は in-app では ref 不明(撮り直しが要る本物の失敗)にも使うので、ホストはこの接頭辞でだけ
// 「このエンジンにはそのルートが無い = フォールバックしてよい」と読む。どれかのブリッジで文言を変えると、
// ルート不明が素の失敗になってフォールバックが黙って効かなくなる(テストは他に無く緑のまま通っていた)。

import XCTest
import FTCore

final class RouteNotFoundPrefixSyncTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// ブリッジごとの「ルートが無い」応答の行(本文の書式を変えたらここも落ちる)
    private let routeNotFoundLines: [(file: String, needle: String)] = [
        ("InAppBridge/Sources/InAppBridge.swift",
         #".error("not found: \(req.method) \(req.path)", status: 404)"#),
        ("Runner/FleetestRunnerUITests/BridgeRouter.swift",
         #".error("not found: \(request.method) \(request.path)", status: 404)"#),
        ("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java",
         #""not found: " + request.method + " " + request.path"#),
    ]

    func testEveryBridgeAnswersAnUnknownRouteWithTheDeclaredPrefix() throws {
        for (file, needle) in routeNotFoundLines {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains(needle), "\(file) の未知ルートの本文が変わった: \(needle)")
        }
    }

    /// ホストの判定がその本文を「ルートが無い」と読み、ref 不明の 404 は読まないこと
    func testHostReadsTheRouteNotFoundBodyAsEngineIncapable() {
        XCTAssertTrue(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 404, body: "not found: POST /drag")))
        XCTAssertFalse(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 404, body: "unknown reference number 3")))
    }
}
