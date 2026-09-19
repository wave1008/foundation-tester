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
                .appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// ルータは status を**2書式**で返す(`throw BridgeError(501, …)` と
    /// `.error(…, status: 501)`)。片方しか数えないと**もう片方で足した分を見逃す** ——
    /// 実際に `handleHideKeyboard` の 501 が「0箇所」の主張をすり抜けていた
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

    /// **取得系はセッションのアプリが前面のときだけ木を撮る**(`requireForegroundApp`)。
    ///
    /// 外すと 45 秒待たされた末に**ランナーごと落ちてブリッジが消える**(2026-08-15 実測 6/6)。
    /// `requireLiveApp` では代用できない —— あちらは `.notRunning`/`.unknown` しか弾かず、
    /// 引き金の**背面**(`.runningBackground`)を素通しする。
    /// 状態は 422 であること: 409 はセッション消失専用、503 は `AppAttachDriver` が
    /// activate で復帰を試みる = 呼び手に黙ってアプリを前面へ引き戻す
    func testTreeReadsRequireTheAppToBeInTheForeground() throws {
        let source = try routerSource
        for handler in ["handleSnapshot", "handleHittable"] {
            let body = try XCTUnwrap(handlerBody(handler, in: source), "\(handler) が見つからない")
            XCTAssertTrue(body.contains("try requireForegroundApp()"),
                          "\(handler) は requireForegroundApp() を通すこと"
                          + "(背面のまま木を撮るとランナーが落ちてブリッジが消える)")
        }
        let guardBody = try XCTUnwrap(handlerBody("requireForegroundApp", in: source))
        XCTAssertTrue(guardBody.contains("BridgeError(422,"),
                      "前面でないことの申告は 422(409 = セッション消失 / "
                      + "503 = AppAttachDriver が黙って activate する)")
        XCTAssertTrue(guardBody.contains("== .runningForeground"),
                      "背面を弾くには前面と等しいことを要求すること"
                      + "(.notRunning の否定では .runningBackground が素通りする)")
    }

    /// **回転はセッションのアプリが前面で生きているときだけ窓を読む**(`requireForegroundAppForRotation`)。
    /// 判定は `app.frame` を読むので、落ちた・背面のアプリで読むと XCTest が Tear Down してランナーごと消える
    /// (2026-09-19 負荷テスト: クラッシュ後の ft_rotate でブリッジが消えた。起動 → 停止 → rotate で毎回再現)。
    /// 待ちの途中で消えた形も `appOrientation` が前面を確かめてから読むことで止める
    func testRotationReadsTheWindowOnlyWhileTheAppIsInTheForeground() throws {
        let source = try routerSource
        let rotate = try XCTUnwrap(handlerBody("handleRotate", in: source))
        XCTAssertTrue(rotate.contains("try requireForegroundAppForRotation()"),
                      "handleRotate はセッションがあるとき requireForegroundAppForRotation() を通すこと")
        let guardBody = try XCTUnwrap(handlerBody("requireForegroundAppForRotation", in: source))
        XCTAssertTrue(guardBody.contains("try requireLiveApp()"), "落ちたアプリは requireLiveApp の 503 で断る")
        XCTAssertTrue(guardBody.contains("BridgeError(422,") && guardBody.contains("== .runningForeground"),
                      "背面は前面と等しいことを要求して 422 で断る")
        let orientation = try XCTUnwrap(handlerBody("appOrientation", in: source))
        let check = try XCTUnwrap(orientation.range(of: "app.state == .runningForeground"),
                                  "appOrientation は窓を読む前に前面を確かめること")
        let read = try XCTUnwrap(orientation.range(of: "app.frame"))
        XCTAssertLessThan(check.lowerBound, read.lowerBound, "前面の確認は app.frame より前")
    }

    /// **消去(/clear)は欄に触る直前に毎回在るかを確かめる**(`requirePresent` / `presentRemainingText`)。
    /// 消えた要素の value / frame / typeText は XCTest の失敗を記録し、3 件目で Tear Down してランナーごと
    /// 消える(2026-09-19: WebView の中身を消去の途中で止めると毎回再現)。`exists` は失敗を記録しない
    func testClearChecksTheFieldStillExistsBeforeTouchingIt() throws {
        let source = try routerSource
        let clear = try XCTUnwrap(handlerBody("handleClear", in: source))
        XCTAssertFalse(clear.contains("Self.remainingText(of: focused)"),
                       "handleClear の読み取りは presentRemainingText を通すこと(素の remainingText は在るかを見ない)")
        var searchFrom = clear.startIndex
        var frames = 0
        while let read = clear.range(of: "let frame = focused.frame", range: searchFrom..<clear.endIndex) {
            frames += 1
            let before = clear[clear.startIndex..<read.lowerBound]
            let lastGuard = before.range(of: "try Self.requirePresent(focused)", options: .backwards)
            let lastRead = before.range(of: "presentRemainingText", options: .backwards)
            XCTAssertNotNil(lastGuard, "focused.frame の前に requirePresent があること")
            if let lastGuard, let lastRead {
                XCTAssertGreaterThan(lastGuard.lowerBound, lastRead.lowerBound,
                                     "frame を読む直前(値を読んだ後)に在るかを確かめ直すこと")
            }
            searchFrom = read.upperBound
        }
        XCTAssertEqual(frames, 2, "focused.frame を読む箇所の数が変わった = この走査を見直すこと")
        let guardStart = try XCTUnwrap(source.range(of: "private static func requirePresent"))
        let guardBody = String(source[guardStart.upperBound...].prefix(600))
        XCTAssertTrue(guardBody.contains("element.exists") && guardBody.contains("BridgeError(422,"),
                      "在るかは exists(失敗を記録しない)で見て、無ければ 422")
    }

    /// **ランナーのテストは XCUI の失敗を記録しない**(`FleetestBridgeTests.record(_:)` がログにだけ残す)。
    /// 記録すると1件でも Tear Down してランナーごとブリッジが消える(2026-09-19: 消えた欄への typeText の失敗
    /// 1件で Tear Down・毎回再現 → 上書き後は同じ手順5回で失敗12件をログに残して生存)。`super` を呼ぶと元に戻る
    func testRunnerTestDoesNotRecordXCUIFailures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runner/FleetestRunnerUITests/FleetestBridgeTests.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "override func record(_ issue: XCTIssue)"),
                                  "FleetestBridgeTests が record(_:) を上書きしていない")
        let body = String(source[start.upperBound...].prefix(400))
        let end = body.range(of: "\n    }")?.lowerBound ?? body.endIndex
        XCTAssertFalse(body[..<end].contains("super.record"), "super を呼ぶと失敗が記録され Tear Down する")
    }

    /// `private func <名>` から次の `private func` の手前まで
    private func handlerBody(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "private func \(name)") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    private func ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// XCUITest ランナーの 501 は `handleHideKeyboard` の**1箇所だけ**。
    /// 501 は isEngineIncapable が真になり、ホストは XCUITest へフォールバックする ——
    /// つまり**フォールバック先が自分自身**になるので、増やすと無限の遠回りを作る。
    ///
    /// 唯一の例外が hideKeyboard で、これは iOS に実装手段が無い(§10)ため in-app も
    /// XCUITest も 501 を返す。ホスト(`StepExecutor`)は in-app の 501 を typeDriver へ
    /// **1回だけ**回し、そこでも 501 なら失敗させるので、遠回りは1往復で止まる。
    /// **これ以外の 501 を足さないこと**(「今は無理」は 422)
    /// **ホームボタン機の appSwitcher は断る**(2026-08-28・実機 iPhone SE3 で2案とも実測)。
    /// 黙って別の面(コントロールセンター / ホーム)を開いて ok を返していたので、
    /// 「できないと言う」ことそのものが仕様。**501 ではなく 422**(501 は他エンジンへの
    /// フォールバック指示で、実機には代わりが無い)
    func testAppSwitcherRefusesOnHomeButtonPhonesInsteadOfDoingSomethingElse() throws {
        let source = try routerSource
        XCTAssertTrue(source.contains("the app switcher cannot be opened on a home-button iPhone"),
                      "ホームボタン機で appSwitcher を断る分岐が消えている")
        XCTAssertTrue(source.contains("isHomeButtonPhone"),
                      "機種判定が消えている(全機に Face ID のジェスチャを撃つ状態へ戻っている)")
    }

    func testRunnerNeverClaimsEngineIncapable() throws {
        let source = try routerSource
        XCTAssertEqual(try throwSites(status: 501, in: source), 1,
                       "XCUITest ランナーの 501 は hideKeyboard の1箇所だけ。"
                       + "増やすとフォールバック先が自分自身になる")
        XCTAssertTrue(source.contains("hideKeyboard is Android-only"),
                      "501 の1箇所は hideKeyboard であること")
    }
}
