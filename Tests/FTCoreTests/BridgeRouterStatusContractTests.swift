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

    /// ルータは status を**2書式**で返す(`throw BridgeError(501, …)` と
    /// `.error(…, status: 501)`)。片方しか数えないと**もう片方で足した分を見逃す** ——
    /// 実際に `handleHideKeyboard` の 501 が「0箇所」の主張をすり抜けていた(2026-08-04)
    private func throwSites(status: Int, in source: String) throws -> Int {
        let patterns = [#"BridgeError\(\#(status)\s*,"#, #"status:\s*\#(status)\b"#]
        return try patterns.reduce(0) { total, pattern in
            let regex = try NSRegularExpression(pattern: pattern)
            return total + regex.numberOfMatches(
                in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
        }
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
        // 文言は英語(ブリッジのメッセージはホストへ素通しするため。CLAUDE.md の方針)。
        // **目印は経路の意味**なので、言い回しを変えるときはここも直す
        XCTAssertTrue(source.contains("the XCUITest runner has no session"),
                      "409 の1箇所はセッション消失の requireApp() であること")
    }

    /// 503 も同様に requireLiveApp() だけ(アプリ未起動の申告)
    func testAppNotRunningStatusIsThrownFromExactlyOneSite() throws {
        XCTAssertEqual(try throwSites(status: 503, in: try routerSource), 1,
                       "503 は requireLiveApp() の1箇所だけ")
    }

    /// XCUITest ランナーの 501 は `handleHideKeyboard` の**1箇所だけ**。
    /// 501 は isEngineIncapable が真になり、ホストは XCUITest へフォールバックする ——
    /// つまり**フォールバック先が自分自身**になるので、増やすと無限の遠回りを作る。
    ///
    /// 唯一の例外が hideKeyboard で、これは iOS に実装手段が無い(§10)ため in-app も
    /// XCUITest も 501 を返す。ホスト(`StepExecutor`)は in-app の 501 を typeDriver へ
    /// **1回だけ**回し、そこでも 501 なら失敗させるので、遠回りは1往復で止まる。
    /// **これ以外の 501 を足さないこと**(「今は無理」は 422)
    func testRunnerNeverClaimsEngineIncapable() throws {
        let source = try routerSource
        XCTAssertEqual(try throwSites(status: 501, in: source), 1,
                       "XCUITest ランナーの 501 は hideKeyboard の1箇所だけ。"
                       + "増やすとフォールバック先が自分自身になる")
        XCTAssertTrue(source.contains("hideKeyboard is Android-only"),
                      "501 の1箇所は hideKeyboard であること")
    }
}
