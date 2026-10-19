// ft_batch: 複数の operation/scroll DSL ステップを1回の承認で実行する。
//
// 実行は StepExecutor に委ねる(ft_scroll_to と同じ driver/ヒント解決を共有 —
// MCPServer.resolveExecutorHints)。ここで固定するのは MCP 側の契約だけ:
// 受け付けるコマンドの絞り込み(DSLCommandIndex 由来)・セレクタを取らないコマンドでの ref 拒否・
// 上限・最初の失敗で停止・木は最後に1回だけ・実行した手が InteractionLog に残ること。
// **1手目に限る ref の受理・解決・2手目以降の拒否は MCPBatchFirstStepRefTests が見る**
//。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPBatchTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func steps(_ dsl: String) -> [String: Any] {
        ["steps": dsl]
    }

    /// 打ち込み先の入力欄を木に足す(type / clearInput は入力欄でない型を撃つ前に断るので、#login_btn へは打てない)
    private func addTextField() {
        driver.typedTextVerified = true
        driver.snapshotResponse.elements.append(
            ElementInfo(ref: 2, type: "TextField", identifier: "field_email", label: nil, value: nil,
                        placeholder: "メール", enabled: true,
                        frame: FTRect(x: 10, y: 80, width: 300, height: 40), depth: 1))
    }

    // MARK: - 欄を空にする type(replace: true + 空文字)

    /// **シナリオに書ける行は batch も通す**: `type("#field", "", replace: true)` は DSL でも
    /// `ft_type` でも「欄を空にする」形。ここを断ると「通ったバッチはシナリオ行になる」の
    /// 逆向きが成り立たない
    func testEmptyTextWithReplaceEmptiesTheField() async throws {
        addTextField()
        let text = body(try await server.call(tool: "ft_batch",
                                              args: steps("type '#field_email' '' replace: true")))
        XCTAssertTrue(text.contains("(replace)"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("type(") }, "\(driver.calls)")
    }

    /// **replace 無しの空文字は断る**(何も起きない手なので、通すと黙って無駄な1手になる)。
    /// 断り文は代わりに撃つものを名指しする
    func testEmptyTextWithoutReplaceIsRefusedAndNamesClearInput() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("type '#field' ''"))
            XCTFail("replace 無しの空文字が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("clearInput"),
                          error.localizedDescription)
        }
    }

    // MARK: - 座標タップ(2026-08-16 に解禁)

    /// **座標タップはバッチで通る**(DSL の `tap(x:y:)` へ 1:1 で書き出せる)。
    /// 要素を1つも公開しない画面のための唯一の手なので、
    /// ここを塞ぐとバッチが「9.3% の要素には使えない道具」になる
    func testCoordinateTapRunsInABatch() async throws {
        let text = body(try await server.call(tool: "ft_batch",
                                              args: steps("tap x: 120 y: 640")))
        XCTAssertTrue(text.contains("tap (120"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(x:") }, "\(driver.calls)")
    }

    /// **セレクタと座標の併記は拒否する**。黙ってどちらかを選ぶと、読み手は自分が何を
    /// 撃ったのか分からないまま次の手を組む
    func testCoordinateTapWithASelectorIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: steps("tap '#btn' x: 10 y: 20"))
            XCTFail("セレクタと座標の併記が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not both"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "弾いた手はドライバへ触れないこと")
    }

    /// `maxGestureSeconds:` 付きの座標長押しがバッチを通ってドライバへ届くこと(既定 10 秒を
    /// 超える holdSeconds を上書きで許す形。CLAUDE.md「ft_batch は DSL の行を受けるので、索引の
    /// signature を変えたら batchStepBuilders のキーも同時に変える」の実地確認)
    func testCoordinateTapWithHoldSecondsAndMaxGestureSecondsRunsInABatch() async throws {
        let text = body(try await server.call(
            tool: "ft_batch", args: steps("tap x: 10 y: 20 holdSeconds: 30 maxGestureSeconds: 30")))
        XCTAssertFalse(text.contains("FAILED"), text)
        XCTAssertTrue(driver.calls.contains { $0 == "press(x:10.0,y:20.0,duration:30.0)" },
                     "\(driver.calls)")
    }

    /// 上書き無しで既定 10 秒を超えたら、デバイスに触れる前にバッチごと拒否すること
    func testCoordinateTapHoldSecondsAboveDefaultCapWithoutOverrideIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: steps("tap x: 10 y: 20 holdSeconds: 10.5"))
            XCTFail("holdSeconds 10.5(上書き無し)の batch 行が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("maxGestureSeconds"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "弾いた手はドライバへ触れないこと")
    }

    /// 片方だけの指定は「どこを撃つのか」が決まらないので拒否(黙って中心を撃たない)
    func testCoordinateTapNeedsBothAxes() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("tap x: 10"))
            XCTFail("y の無い座標タップが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("both x and y"),
                          error.localizedDescription)
        }
    }

    // MARK: - (a) 操作系でないコマンドは弾かれ、代わりの呼び方が本文に出る

    func testAppLifecycleCommandIsRejectedWithTheToolToCallInstead() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("launchApp"))
            XCTFail("launchApp がバッチで通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ft_launch"), message)
        }
        XCTAssertEqual(driver.calls, [], "弾いた手はドライバへ触れないこと")
    }

    // MARK: - launch: / waitFor:(1回の呼び出しに詰める)

    /// **launch: は ft_launch の本体を手より先に通す**(起動の記憶・下書きの起点が ft_launch と同じになる)
    func testLaunchRunsFtLaunchBeforeTheSteps() async throws {
        let text = body(try await server.call(tool: "ft_batch",
                                              args: ["steps": "tap '#login_btn'", "launch": "com.example.app"]))
        XCTAssertTrue(text.contains("0. launch com.example.app — ok"), text)
        let launchAt = try XCTUnwrap(driver.calls.firstIndex(of: "launch(com.example.app)"), "\(driver.calls)")
        let tapAt = try XCTUnwrap(driver.calls.firstIndex { $0.hasPrefix("tap(") }, "\(driver.calls)")
        XCTAssertLessThan(launchAt, tapAt, "\(driver.calls)")
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(draft.contains("@TestClass"), draft)
        XCTAssertFalse(draft.contains("@TestClass(app:"), draft)
    }

    /// **起動し直す前に読んだ ref は使わせない**(起動後の画面に同じ ref は無い)。デバイスに触る前に断る
    func testLaunchWithAFirstStepRefIsRefusedBeforeTouchingTheDevice() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "tap ref: 1", "launch": "com.example.app"])
            XCTFail("launch: と1手目の ref の併用が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("before the relaunch"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains("launch(com.example.app)"), "\(driver.calls)")
    }

    /// **waitFor: は最後の画面を読む前に待ち、出たか出なかったかを言う**(出なくても失敗にはしない = 他のツールの waitFor と同じ)
    func testWaitForReportsWhetherTheSelectorAppeared() async throws {
        driver.changeTreeOnEveryTap()
        let found = body(try await server.call(tool: "ft_batch",
                                               args: ["steps": "tap '#login_btn'", "waitFor": "#login_btn"]))
        XCTAssertTrue(found.contains("waitFor \"#login_btn\" appeared: matched ["), found)
        let missing = body(try await server.call(tool: "ft_batch",
                                                 args: ["steps": "tap '#login_btn'", "waitFor": "#no_such_id",
                                                        "waitSeconds": 0.2]))
        XCTAssertTrue(missing.contains("waitFor \"#no_such_id\" did not appear"), missing)
        XCTAssertTrue(missing.contains("All 1 step(s) passed."), missing)
    }

    /// **検証は実行より前に全手へ通す**。他の拒否テストは1手目が不正なので、検証を実行ループの
    /// 中へ移す変更を通してしまう —— その形だと**前半の手だけがデバイスに残る**(やり直せば
    /// 二重に押されるし、探索の前提も崩れる)。ここでは有効な手の後ろに不正な手を置く
    func testAnInvalidLaterStepStopsTheWholeBatchBeforeAnythingRuns() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: steps("tap '#login_btn'; launchApp"))
            XCTFail("2手目が不正なのにバッチが走った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("step 2"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "1手目もデバイスへ通さないこと")
    }

    /// gesture はトレイリングクロージャ(FTGestureBuilder)を取るので1行の DSL に落とせない
    /// (category は operation で allowed だが `batchStepBuilders` に無い —— MCPServer+Batch.swift の
    /// `batchUnsupportedGuidance`)。ft_gesture を直接呼ぶよう案内する
    func testGestureIsRejectedWithFtGestureGuidance() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("gesture"))
            XCTFail("gesture がバッチで通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ft_gesture"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    /// clearAppData も同じ経路(データ消去まで1回の承認で届かせない、が主目的)
    func testClearAppDataIsRejected() async {
        do {
            _ = try await server.call(
                tool: "ft_batch",
                args: steps("clearAppData 'com.example.app'"))
            XCTFail("clearAppData がバッチで通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ft_clear_app_data"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    /// アサーションは operation/scroll ではないので弾く(今回は操作系のみ)
    func testAssertionCommandIsRejectedAsNotAnOperation() async {
        do {
            _ = try await server.call(
                tool: "ft_batch",
                args: steps("exist '#login_btn'"))
            XCTFail("exist がバッチで通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("assertion"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - (b) 未知のコマンド名は ft_dsl_commands を案内して弾かれる

    func testUnknownCommandNameIsRejectedAndPointsToDslCommands() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("tapAndHold"))
            XCTFail("未知のコマンドが通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ft_dsl_commands"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - (c) 最初の失敗で止まり、以降のステップが実行されない

    func testStopsAtTheFirstFailureAndDoesNotRunLaterSteps() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps(
                "tap '#login_btn'; tap '#does_not_exist' waitSeconds: 0.0; tap '#login_btn'"))
            XCTFail("見つからないセレクタを含むバッチが成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Stopped at step 2 of 3"), message)
            XCTAssertTrue(message.contains("later steps were not run"), message)
        }
        // 1本目の tap は撃たれ、2本目は解決に失敗して撃たれず、3本目は実行されない ——
        // ドライバの呼び出し列には tap(ref:) が1回だけ残る(2本目の失敗後に撮り直す snapshot は別途入る)
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("tap(") }, ["tap(ref:1)"],
                       "\(driver.calls)")
    }

    /// 失敗した手の後の撮り直しが投げても(撃った手でアプリが落ちた形)、手ごとの結果と止まった位置を返す
    func testStepResultsSurviveWhenTheSnapshotAfterAFailureThrows() async {
        driver.failing = ["tap"]
        driver.snapshotsFailAfterCallPrefix = "tap("
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("tap '#login_btn'; tap '#login_btn'"))
            XCTFail("失敗した手を含むバッチが成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("1. ") && message.contains("FAILED"), message)
            XCTAssertTrue(message.contains("Stopped at step 1 of 2"), message)
            XCTAssertTrue(message.contains("Could not take a snapshot after the failure"), message)
        }
    }

    /// セレクタが2件以上に一致したら、batch の行に「1件目を撃った」と添える
    func testAmbiguousSelectorIsFlaggedInTheStepLine() async throws {
        let ok = { (ref: Int, y: Double) in
            ElementInfo(ref: ref, type: "button", identifier: nil, label: "OK", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 10, y: y, width: 100, height: 40), depth: 1)
        }
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ok(1, 100), ok(2, 300)], truncatedCount: 0)
        let result = try await server.call(tool: "ft_batch", args: steps("tap 'OK'"))
        XCTAssertTrue(body(result).contains("matched 2 elements"), body(result))
        // 同名の2件はラベルでは区別できないので、撃った方を位置で名指しする
        XCTAssertTrue(body(result).contains("the first one was used (button \"OK\" at 10,100 100x40)"), body(result))
    }

    /// **ok でも画面が変わらなかった tap は結論で「passed」と言わない**(実測: シートが出てくる途中の tap が飲まれ、
    /// "All 4 step(s) passed")。中間の手は次の tap の撃つ前の木、最後の手は最後の木と比べる
    func testATapThatLeftTheScreenUnchangedIsNamedInTheVerdict() async throws {
        coverTheScreen()
        let result = body(try await server.call(tool: "ft_batch", args: steps("tap '#login_btn'; tap '#login_btn'")))
        XCTAssertTrue(result.contains("step(s) 1, 2 may have done nothing"), result)
        XCTAssertFalse(result.contains("step(s) passed"), result)
        XCTAssertTrue(result.contains("the screen did not change after this tap"), result)
    }

    /// **掴むだけの手(waitForSettle)を挟んでも、tap の前の木どうしを比べない**(実測: tap → waitForSettle で効いた tap を毎回名指した)
    func testAGrabOnlyStepAfterATapDoesNotNameIt() async throws {
        coverTheScreen()
        driver.changeTreeOnEveryTap()
        driver.waitForSettleResponse = WaitForSettleResponse(settled: true, elapsedMs: 400, frames: 3)
        let result = body(try await server.call(tool: "ft_batch",
                                                args: steps("tap '#login_btn'; waitForSettle; tap '#login_btn'")))
        XCTAssertTrue(result.contains("All 3 step(s) passed."), result)
    }

    /// **木が空同然の画面では「変化なし」が常に真**なので名指さない(batchUnchangedNote と同じ但し書きの閾値)
    func testAnUnrepresentedScreenDoesNotNameUnchangedTaps() async throws {
        let result = body(try await server.call(tool: "ft_batch", args: steps("tap '#login_btn'; tap '#login_btn'")))
        XCTAssertFalse(result.contains("may have done nothing"), result)
    }

    /// 画面全体を覆う容器を足す(既定の木は小さな要素だけで、画面の大半が木に載っていない形になる)
    private func coverTheScreen() {
        driver.snapshotResponse.elements.insert(ElementInfo(
            ref: 500, type: "other", identifier: "root", label: nil, value: nil, placeholder: nil, enabled: true,
            frame: driver.snapshotResponse.screen, depth: 0), at: 0)
    }

    func testTapsThatChangedTheScreenStillPass() async throws {
        driver.changeTreeOnEveryTap()
        let result = body(try await server.call(tool: "ft_batch", args: steps("tap '#login_btn'; tap '#login_btn'")))
        XCTAssertTrue(result.contains("All 2 step(s) passed."), result)
    }

    /// **無効な要素への tap は撃った上で ok(DSL と同じ)だが、結論で名指す**。launch: の行があっても手の番号はずれない
    func testATapOnADisabledTargetIsNamedInTheVerdict() async throws {
        driver.changeTreeOnEveryTap()
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "next", label: "Next", value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 10, y: 100, width: 100, height: 40), depth: 1),
                       ElementInfo(ref: 2, type: "button", identifier: "done", label: "Done", value: nil, placeholder: nil,
                                   enabled: false, frame: FTRect(x: 10, y: 300, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)
        let result = body(try await server.call(tool: "ft_batch",
                                                args: ["steps": "tap '#next'; tap '#done'", "launch": "com.example.app"]))
        XCTAssertTrue(result.contains("step(s) 2 may have done nothing"), result)
    }

    // MARK: - (d) 成功時にツリーが1回だけ返る

    func testSuccessfulBatchReturnsExactlyOneTree() async throws {
        let text = body(try await server.call(tool: "ft_batch",
                                              args: steps("tap '#login_btn'; swipe .up")))
        XCTAssertTrue(text.contains("All 2 step(s) passed"), text)
        // 木は render 経由で1回だけ描かれる(screen: が1回)
        let screenLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("screen:") }
        XCTAssertEqual(screenLines.count, 1, text)
        XCTAssertTrue(text.contains("id=login_btn"), text)
    }

    /// 配列形の steps は廃止(ユーザー決定・表記は1つ)。書き換え方を添えて弾く
    func testArrayStepsIsRejectedWithTheRewrite() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: ["steps": ["tap '#login_btn'", "swipe .up"]])
            XCTFail("配列形の steps が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("not an array"), message)
            XCTAssertTrue(message.contains(";"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - type … replace: true(D)。実行は StepExecutor 委譲なので、ここでは配線だけ見る
    // (clearInput→type の呼び出し順・失敗時の扱いは Tests/FTCoreTests/StepExecutorTests+TextEntry.swift
    // が既に固めている)

    func testTypeReplaceClearsBeforeTypingInABatch() async throws {
        addTextField()
        let text = body(try await server.call(
            tool: "ft_batch", args: steps("type '#field_email' 'abc' replace: true")))
        XCTAssertTrue(text.contains("(replace)"), text)
        let clearIndex = driver.calls.firstIndex { $0.hasPrefix("clearInput(ref:") }
        let typeIndex = driver.calls.firstIndex { $0.hasPrefix("type(ref:") }
        XCTAssertNotNil(clearIndex, "replace は type の前に clearInput を呼ぶこと: \(driver.calls)")
        XCTAssertNotNil(typeIndex, "\(driver.calls)")
        if let clearIndex, let typeIndex {
            XCTAssertLessThan(clearIndex, typeIndex,
                              "clearInput は type より前であること: \(driver.calls)")
        }
    }

    // MARK: - (e) 実行した各手が InteractionLog に1手ずつ入り、下書きは正形で出る

    func testExecutedStepsAreRecordedForTheDraft() async throws {
        addTextField()
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_batch",
                                  args: steps("tap '#login_btn'; type '#field_email' 'abc'"))
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\")"), draft)
        XCTAssertTrue(draft.contains("type(\"#field_email\", \"abc\")"), draft)
    }

    // MARK: - (f) ステップ数の上限を超えたら実行前に弾く

    func testTooManyStepsIsRejectedBeforeTouchingTheDriver() async {
        let many = Array(repeating: "tap '#login_btn'", count: MCPServer.batchStepLimit + 1)
            .joined(separator: "; ")
        do {
            _ = try await server.call(tool: "ft_batch", args: steps(many))
            XCTFail("上限超えのバッチが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\(MCPServer.batchStepLimit)"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "上限超えはドライバに一度も触れないこと")
    }

    // MARK: - (g) ref は2手目以降で書けない(1手目だけの例外は MCPBatchFirstStepRefTests)

    /// **2026-08-12 に契約が変わった**: 1手目に限り ref を受け付けるようになったので、
    /// このケース(1手目の ref・直前に ft_snapshot を撮っていない)はもう構文レベルでは拒否
    /// されない — 解決しようとして「直近の snapshot に無い」で止まる。1手目の受理・解決・
    /// 2手目以降の拒否は MCPBatchFirstStepRefTests が見る。ここでは
    /// 「セレクタを取らないコマンドは今も無条件で拒否される」ことだけ固定する
    func testRefOnANonSelectorCommandIsStillRejected() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("swipe ref: 1"))
            XCTFail("swipe に ref 付きのステップが通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("has no \"ref:\" parameter"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    /// 閉じ忘れ・アポストロフィの再オープンは後続の手を1手に呑み込む(splitSteps は引用符の
    /// 中の `;` で区切らない)。呑み込んだ行をそのまま見せるだけでは実際の誤り(引用符)に
    /// 辿り着けないので、可能性を名指しする
    func testUnbalancedQuoteHintNamesTheMerge() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: steps("type '#f' 'it's'; swipe .up"))
            XCTFail("引用符が壊れた steps が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unbalanced quote"),
                          error.localizedDescription)
        }
    }

    // MARK: - 空/欠落した steps

    func testEmptyStepsIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps(""))
            XCTFail("空の steps が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("steps"), error.localizedDescription)
        }
    }

    func testMissingStepsIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: [:])
            XCTFail("steps 無しが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("steps"), error.localizedDescription)
        }
    }

    /// 空白・空行・`;` だけの steps は空扱いで弾く
    func testBlankLinesAreIgnored() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: steps("   ; \n ; "))
            XCTFail("空行だけの steps が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("steps"), error.localizedDescription)
        }
    }

    // MARK: - 未対応ラベルは名指しで拒否される(黙って捨てない)

    func testUnsupportedLabelIsRejectedByName() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: steps("tap '#a' containerInference: true"))
            XCTFail("未対応ラベルが通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("containerInference"), message)
            XCTAssertTrue(message.contains("does not support"), message)
            XCTAssertTrue(message.contains("selector"), message)
        }
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - 改行も手の区切りとして働く(`;` と同義。上限は分割後の手数で数える)

    func testNewlineSplitsIntoMultipleSteps() async throws {
        let text = body(try await server.call(tool: "ft_batch",
                                              args: steps("tap '#login_btn'\nswipe .up")))
        XCTAssertTrue(text.contains("All 2 step(s) passed"), text)
    }

    func testStepLimitCountsSplitLines() async {
        let joined = Array(repeating: "tap '#login_btn'", count: MCPServer.batchStepLimit + 1)
            .joined(separator: "\n")
        do {
            _ = try await server.call(tool: "ft_batch", args: steps(joined))
            XCTFail("改行分割後に上限を超えるバッチが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\(MCPServer.batchStepLimit)"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - 割り込みの宣言(irregularHandler)

    /// 「安全に目的地に到達するために」+ OK が前面にある木(Apple マップの実測の形)
    private func treeWithAlert() -> SnapshotResponse {
        var tree = driver.snapshotResponse
        tree.elements.append(contentsOf: [
            ElementInfo(ref: 4, type: "alert", identifier: nil, label: "安全に目的地に到達するために",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 41, y: 355, width: 320, height: 192), depth: 1),
            ElementInfo(ref: 5, type: "button", identifier: nil, label: "OK", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 57, y: 483, width: 288, height: 48), depth: 2),
        ])
        return tree
    }

    /// **宣言した割り込みは、後続の手の開始時に閉じてから撃つ**
    func testDeclaredInterruptionIsClosedBeforeTheNextStep() async throws {
        driver.scriptedSnapshots = [treeWithAlert()]
        let text = body(try await server.call(tool: "ft_batch", args: steps(
            "irregularHandler '安全に目的地に到達するために' dismiss: 'OK'; tap '#login_btn'")))
        XCTAssertTrue(text.contains("declared"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
        let closeAt = try XCTUnwrap(driver.calls.firstIndex(of: "tap(ref:5)"), "OK が押されていない: \(driver.calls)")
        let tapAt = try XCTUnwrap(driver.calls.firstIndex(of: "tap(ref:1)"), "\(driver.calls)")
        XCTAssertLessThan(closeAt, tapAt, "\(driver.calls)")
    }

    /// **陰性対照**: 宣言が無ければ閉じない(ツールが勝手に押さない)
    func testUndeclaredInterruptionIsNotClosed() async throws {
        driver.scriptedSnapshots = [treeWithAlert()]
        _ = try? await server.call(tool: "ft_batch", args: steps("tap '#login_btn'"))
        XCTAssertFalse(driver.calls.contains("tap(ref:5)"), "\(driver.calls)")
    }

    /// **呼び出しごとに書いた同じ宣言は、下書きでは1行**。宣言は DSL の行として書き出す
    func testRepeatedDeclarationAppearsOnceInTheDraft() async throws {
        for _ in 0..<2 {
            _ = try await server.call(tool: "ft_batch", args: steps(
                "irregularHandler '安全に目的地に到達するために' dismiss: 'OK'; tap '#login_btn'"))
        }
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        let line = "irregularHandler(\"安全に目的地に到達するために\", dismiss: \"OK\")"
        XCTAssertEqual(draft.components(separatedBy: line).count - 1, 1, draft)
    }

    /// **宣言は操作として数えない**(画面を変えないので、古い ref の注記の「このセッションの操作が原因」を誤らせない)
    func testDeclarationDoesNotCountAsASessionAction() async throws {
        _ = try await server.call(tool: "ft_batch", args: steps("irregularHandler 'お知らせ' dismiss: '閉じる'"))
        XCTAssertEqual(server.sessionActionCounts[MCPServer.engineKey([:])] ?? 0, 0)
    }

    /// **宣言は呼び出しを跨がない**: 前の呼び出しで宣言しても、次の呼び出しでは閉じない
    func testDeclarationIsNotCarriedOverToTheNextCall() async throws {
        _ = try await server.call(tool: "ft_batch", args: steps(
            "irregularHandler '安全に目的地に到達するために' dismiss: 'OK'; tap '#login_btn'"))
        driver.scriptedSnapshots = [treeWithAlert()]
        _ = try? await server.call(tool: "ft_batch", args: steps("tap '#login_btn'"))
        XCTAssertFalse(driver.calls.contains("tap(ref:5)"), "\(driver.calls)")
    }
}
