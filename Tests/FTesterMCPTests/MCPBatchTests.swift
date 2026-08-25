// ft_batch: 複数の operation/scroll DSL ステップを1回の承認で実行する。
//
// 実行は StepExecutor に委ねる(ft_scroll_to と同じ driver/ヒント解決を共有 —
// MCPServer.resolveExecutorHints)。ここで固定するのは MCP 側の契約だけ:
// 受け付けるコマンドの絞り込み(DSLCommandIndex 由来)・セレクタを取らないコマンドでの ref 拒否・
// 上限・最初の失敗で停止・木は最後に1回だけ・実行した手が InteractionLog に残ること。
// **1手目に限る ref の受理・解決・2手目以降の拒否は MCPBatchFirstStepRefTests が見る**
// (2026-08-12)。

import XCTest
import FTCore
@testable import ftester_mcp

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
                "tap '#login_btn'; tap '#does_not_exist' timeout: 0.0; tap '#login_btn'"))
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

    /// 配列形の steps は廃止(2026-08-10 ユーザー決定・表記は1つ)。書き換え方を添えて弾く
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

    // MARK: - (e) 実行した各手が InteractionLog に1手ずつ入り、下書きは正形で出る

    func testExecutedStepsAreRecordedForTheDraft() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_batch",
                                  args: steps("tap '#login_btn'; type '#login_btn' 'abc'"))
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\")"), draft)
        XCTAssertTrue(draft.contains("type(\"#login_btn\", \"abc\")"), draft)
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
}
