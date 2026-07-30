// XCUITest ランナーの HTTP ステータスの意味づけを守る。
//
// ホスト側は**ステータス番号だけ**で分岐しており、番号ごとに別の回復動作が走る:
//   409 → SessionRecoveryDriver がセッション消失と断定し activate で張り直す
//   503 → アプリが起動していない(requireLiveApp)
//   501 / "not found:" 付き 404 → このエンジンでは不可 = XCUITest へフォールバック
//         (DriverError.isEngineIncapable)
// つまり番号を1つ足すだけで、無関係な回復動作が黙って発火する。
//
// 実害(2026-07-31): handleClear が「フォーカス欄が無い」「消し切れなかった」に 409 を使ったため、
// clearInput の正当な失敗が「ランナーが再起動した可能性」と誤報告され、無用な activate まで
// 撃っていた。E2E の失敗理由が読めなくなる。以後この本数をここで固定する。

import XCTest

final class BridgeRouterStatusContractTests: XCTestCase {

    private var routerSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // FTCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // リポジトリルート
                .appendingPathComponent("Runner/FTesterRunnerUITests/BridgeRouter.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func throwSites(status: Int, in source: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: #"BridgeError\(\#(status)\s*,"#)
        return regex.numberOfMatches(in: source,
                                     range: NSRange(source.startIndex..<source.endIndex, in: source))
    }

    /// 409 は `requireApp()` のセッション消失だけ。**増やしてはいけない**:
    /// ホストは経路を問わず 409 を「セッション消失」と断定して activate を撃つ。
    /// 「セッションはあるが今は無理」は 422 を使うこと(handleClear が前例)
    func testSessionLostStatusIsThrownFromExactlyOneSite() throws {
        let source = try routerSource
        XCTAssertEqual(try throwSites(status: 409, in: source), 1,
                       "XCUITest ランナーの 409 は requireApp() の1箇所だけ。"
                       + "「セッションはあるが実行できない」は 422 を使うこと"
                       + "(SessionRecoveryDriver がセッション消失と誤断定し activate を撃つ)")
        XCTAssertTrue(source.contains("ランナーにセッションがありません"),
                      "409 の1箇所はセッション消失の requireApp() であること")
    }

    /// 503 も同様に requireLiveApp() だけ(アプリ未起動の申告)
    func testAppNotRunningStatusIsThrownFromExactlyOneSite() throws {
        XCTAssertEqual(try throwSites(status: 503, in: try routerSource), 1,
                       "503 は requireLiveApp() の1箇所だけ")
    }

    /// XCUITest ランナーは「このエンジンでは不可」を持たない(全ルートを実装している)。
    /// 501 を足すと isEngineIncapable が真になり、ホストが**同じ XCUITest へ**
    /// フォールバックする無限の遠回りになる
    func testRunnerNeverClaimsEngineIncapable() throws {
        XCTAssertEqual(try throwSites(status: 501, in: try routerSource), 0,
                       "XCUITest ランナーが 501 を返すとフォールバック先が自分自身になる")
    }
}
