// MCP(ft_*)の数値引数は型だけ検査していて値域(0/負・上限超え)を素通ししていた ——
// `lastN` の範囲検査(旧 MCPServer+Draft.swift)だけが個別に直されていて、他へ掃討されていなかった。
// 実地: maxElements:0/-5/999999, maxSwipes:-3, lines:-10, sinceSeconds:-1000, maxWidth:0,
// quality:0/5, holdSeconds:-3, radius:-50, durationSeconds:-1 が黙って通っていた。
// 値域の唯一の定義元は FTCore.ArgumentBounds(数値の表 + 空文字を断る文字列の集合)。
// ここでは①スキーマの数値/必須文字列プロパティが表に載っていること(等号ではなく包含 —
// 座標のように値域を持たない引数も `.unbounded` で必ず載る)②実物の呼び口が実際に断ること
// ③境界の内側は通ることを固定する。

import XCTest
import FTCore
@testable import fleetest_mcp

final class ArgumentBoundsTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - ①スキーマ走査: 数値/必須文字列プロパティが表に載っているか

    func testEverySchemaNumericPropertyHasABound() {
        var numericKeys: Set<String> = []
        for tool in MCPServer.toolDefinitions {
            guard let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { continue }
            for (key, value) in properties {
                guard let prop = value as? [String: Any], let type = prop["type"] as? String else { continue }
                if type == "integer" || type == "number" { numericKeys.insert(key) }
            }
        }
        XCTAssertFalse(numericKeys.isEmpty)
        let missing = numericKeys.subtracting(ArgumentBounds.numeric.keys)
        XCTAssertTrue(missing.isEmpty, "ArgumentBounds.numeric に無いスキーマの数値引数: \(missing)"
            + " — 値域を持たない引数でも .unbounded で載せること")
    }

    /// enum 制約のある必須文字列(orientation/target/direction)は選択肢そのものが値域なので除く
    /// (別の門で断っている — FTOrientation.parse 等)
    func testEveryRequiredStringPropertyMustNotBeEmpty() {
        var requiredStringKeys: Set<String> = []
        for tool in MCPServer.toolDefinitions {
            guard let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any],
                  let required = schema["required"] as? [String] else { continue }
            for key in required {
                guard let prop = properties[key] as? [String: Any],
                      prop["type"] as? String == "string", prop["enum"] == nil else { continue }
                requiredStringKeys.insert(key)
            }
        }
        XCTAssertFalse(requiredStringKeys.isEmpty)
        let missing = requiredStringKeys.subtracting(ArgumentBounds.mustNotBeEmpty)
        XCTAssertTrue(missing.isEmpty, "ArgumentBounds.mustNotBeEmpty に無い必須文字列引数: \(missing)")
    }

    /// `ft_batch` の DSL 行は `MCPServer.intArgument`/`doubleArgument` を経由しないので、
    /// `BatchStepResolver.intKeys`/`doubleKeys`(ft_batch の辞書キー語彙)が
    /// `ArgumentBounds.numeric` に全部載っていることを別途固定する
    /// (MCPServer+Batch.swift の `checkBatchArgumentBounds` が唯一の呼び口)
    func testEveryBatchNumericKeyHasABound() {
        let batchKeys = BatchStepResolver.intKeys.union(BatchStepResolver.doubleKeys)
        XCTAssertFalse(batchKeys.isEmpty)
        let missing = batchKeys.subtracting(ArgumentBounds.numeric.keys)
        XCTAssertTrue(missing.isEmpty, "ArgumentBounds.numeric に無い ft_batch の数値鍵: \(missing)")
    }

    // MARK: - ②値域そのもの(FTCore.ArgumentBounds を直接叩く)

    func testViolationNamesTheKeyAndTheOffendingValue() {
        let cases: [(String, Double)] = [
            ("maxElements", 0), ("maxElements", -5), ("maxElements", 999_999),
            ("maxSwipes", -3), ("lines", -10), ("sinceSeconds", -1000),
            ("maxWidth", 0), ("quality", 0), ("quality", 5),
            ("holdSeconds", -3), ("durationSeconds", -1), ("radius", -50),
            ("timeout", -1), ("lastN", 0),
        ]
        for (key, value) in cases {
            let message = ArgumentBounds.violation(key, value)
            XCTAssertNotNil(message, "\(key)=\(value) は断られるはず")
            XCTAssertTrue(message?.contains(key) == true, message ?? "nil")
        }
    }

    func testBoundaryValuesAreAccepted() {
        let cases: [(String, Double)] = [
            ("maxElements", 1), ("maxElements", Double(BridgeAPI.maxSnapshotElementsCeiling)),
            ("maxSwipes", 0), ("timeout", 0), ("quality", 1), ("lastN", 1),
        ]
        for (key, value) in cases {
            XCTAssertNil(ArgumentBounds.violation(key, value), "\(key)=\(value) は境界内のはず")
        }
    }

    /// hold/gesture 系(holdSeconds/durationSeconds/duration/press)は10秒を超えると断る。
    /// リテラルの 10 / 10.5 を書く(production の `maxGestureSeconds` を期待値に流用しない ——
    /// 定数を書き換えても壊れないテストになってしまう)
    func testGestureDurationKeysRejectAboveTenSeconds() {
        for key in ["holdSeconds", "durationSeconds", "duration", "press"] {
            let message = ArgumentBounds.violation(key, 10.5)
            XCTAssertNotNil(message, "\(key)=10.5 は断られるはず")
            XCTAssertTrue(message?.contains(key) == true, message ?? "nil")
        }
    }

    func testGestureDurationKeysAcceptTenSeconds() {
        for key in ["holdSeconds", "durationSeconds", "duration", "press"] {
            XCTAssertNil(ArgumentBounds.violation(key, 10), "\(key)=10 は境界内のはず")
        }
    }

    func testUnboundedKeysNeverViolate() {
        for key in ["ref", "fromRef", "x", "y", "dx", "dy", "fromX", "fromY", "toX", "toY"] {
            XCTAssertNil(ArgumentBounds.violation(key, -999_999))
        }
    }

    func testEmptyViolationTrimsWhitespaceAndIgnoresUnlistedKeys() {
        XCTAssertNotNil(ArgumentBounds.emptyViolation("bundleId", ""))
        XCTAssertNotNil(ArgumentBounds.emptyViolation("bundleId", "   "))
        XCTAssertNil(ArgumentBounds.emptyViolation("bundleId", "com.example"))
        XCTAssertNil(ArgumentBounds.emptyViolation("text", ""), "mustNotBeEmpty に無い鍵は対象外")
    }

    // MARK: - ③実物の呼び口: 型は合っているが値がおかしい呼び出しが実際に断られる

    func testSnapshotMaxElementsOutOfRangeIsRejected() async {
        for value in [0, -5, 999_999] {
            do {
                _ = try await server.call(tool: "ft_snapshot", args: ["maxElements": value])
                XCTFail("maxElements \(value) が通った")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("maxElements"), error.localizedDescription)
            }
        }
    }

    func testSnapshotMaxElementsAtTheBoundsSucceeds() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["maxElements": 1])
        _ = try await server.call(tool: "ft_snapshot",
                                  args: ["maxElements": BridgeAPI.maxSnapshotElementsCeiling])
    }

    func testScrollToNegativeMaxSwipesIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_scroll_to",
                                      args: ["selector": "#login_btn", "maxSwipes": -3])
            XCTFail("maxSwipes -3 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("maxSwipes"), error.localizedDescription)
        }
    }

    func testScrollToZeroMaxSwipesSucceeds() async throws {
        let text = body(try await server.call(tool: "ft_scroll_to",
                                              args: ["selector": "#login_btn", "maxSwipes": 0]))
        XCTAssertTrue(text.contains("scrolled to"), text)
    }

    func testLogsNegativeLinesAndSinceSecondsAreRejected() async {
        do {
            _ = try await server.call(tool: "ft_logs", args: ["lines": -10])
            XCTFail("lines -10 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("lines"), error.localizedDescription)
        }
        do {
            _ = try await server.call(tool: "ft_logs", args: ["sinceSeconds": -1000])
            XCTFail("sinceSeconds -1000 が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("sinceSeconds"), message)
            XCTAssertFalse(message.contains("-1000s"), "意味の無い文言 (\"-1000s\") が復活していないか: \(message)")
        }
    }

    func testScreenshotMaxWidthAndQualityAreRejected() async {
        do {
            _ = try await server.call(tool: "ft_screenshot", args: ["maxWidth": 0])
            XCTFail("maxWidth 0 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("maxWidth"), error.localizedDescription)
        }
        for value in [0.0, 5.0] {
            do {
                _ = try await server.call(tool: "ft_screenshot", args: ["quality": value])
                XCTFail("quality \(value) が通った")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("quality"), error.localizedDescription)
            }
        }
    }

    func testScreenshotQualityOfOneSucceeds() async throws {
        _ = try await server.call(tool: "ft_screenshot", args: ["quality": 1.0])
    }

    func testLongPressNegativeHoldSecondsIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_long_press",
                                      args: ["x": 10.0, "y": 20.0, "holdSeconds": -3.0])
            XCTFail("holdSeconds -3 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("holdSeconds"), error.localizedDescription)
        }
    }

    /// 実地: `ft_long_press {x:10,y:10,holdSeconds:1e9}` が Android で "done" を返していた
    /// (両層が press を 10 秒に丸めて実行するだけで、要求どおりの秒数は撃てていない)
    func testLongPressHugeHoldSecondsIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_long_press",
                                      args: ["x": 10.0, "y": 10.0, "holdSeconds": 1_000_000_000.0])
            XCTFail("holdSeconds 1e9 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("holdSeconds"), error.localizedDescription)
        }
    }

    func testPinchNegativeRadiusIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_pinch", args: ["x": 10.0, "y": 20.0, "radius": -50.0])
            XCTFail("radius -50 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("radius"), error.localizedDescription)
        }
    }

    func testDragNegativeDurationSecondsIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_drag",
                                      args: ["fromX": 10.0, "fromY": 10.0, "toX": 20.0, "toY": 20.0,
                                             "durationSeconds": -1.0])
            XCTFail("durationSeconds -1 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("durationSeconds"), error.localizedDescription)
        }
    }

    /// timeout は snapshotAfter: true のときだけ読まれる(snapshotAfterBodyWithStatus の門)
    func testOpenURLNegativeTimeoutIsRejected() async {
        do {
            _ = try await server.call(tool: "ft_open_url",
                                      args: ["url": "myapp://x", "snapshotAfter": true,
                                             "waitFor": "#anything", "timeout": -1.0])
            XCTFail("timeout -1 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timeout"), error.localizedDescription)
        }
    }

    func testDraftScenarioLastNZeroIsRejected() async {
        _ = try? await server.call(tool: "ft_launch", args: ["bundleId": "com.example"])
        do {
            _ = try await server.call(tool: "ft_draft_scenario", args: ["lastN": 0])
            XCTFail("lastN 0 が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("lastN"), error.localizedDescription)
        }
    }

    /// 実地不具合の実物: DSL 行の `holdSeconds: -1` は型検査(BatchStepResolver)は通るが
    /// 値がおかしい。checkBatchArgumentBounds が resolve の戻り値を舐めて断ることを確かめる
    /// (FakeDriver の既定 snapshot に #tab_home は無いが、値域違反は driver に触れる前に断る)
    func testBatchRejectsNegativeHoldSeconds() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "tap '#tab_home' holdSeconds: -1"])
            XCTFail("holdSeconds -1 の batch 行が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("step 1:"), message)
            XCTAssertTrue(message.contains("holdSeconds"), message)
        }
    }

    /// 境界内(waitSeconds: 0)は通る。座標タップはデバイスへの往復も含め既定の FakeDriver で
    /// 素直に成功する(MCPBatchTests.testCoordinateTapRunsInABatch と同じ形)
    func testBatchAcceptsBoundaryNumericValues() async throws {
        _ = try await server.call(tool: "ft_batch",
                                  args: ["steps": "tap x: 10 y: 20 waitSeconds: 0"])
    }

    // MARK: - 空文字(必須・省略可)

    func testRequiredStringsRejectEmptyAndWhitespaceOnly() async {
        let cases: [(String, [String: Any])] = [
            ("ft_launch", ["bundleId": ""]),
            ("ft_open_url", ["url": "   "]),
            ("ft_install", ["packagePath": ""]),
            ("ft_clear_app_data", ["bundleId": ""]),
        ]
        for (tool, args) in cases {
            do {
                _ = try await server.call(tool: tool, args: args)
                XCTFail("\(tool) \(args) が空文字を通した")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("must not be empty"),
                              "\(tool): \(error.localizedDescription)")
            }
        }
    }

    /// classifier/label は ft_capture_element の必須文字列(ref/selector が無くても先に断る)
    func testCaptureElementRejectsEmptyClassifierAndLabel() async {
        do {
            _ = try await server.call(tool: "ft_capture_element",
                                      args: ["classifier": "", "label": "x"])
            XCTFail("空の classifier が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("classifier must not be empty"),
                          error.localizedDescription)
        }
        do {
            _ = try await server.call(tool: "ft_capture_element",
                                      args: ["classifier": "DefaultClassifier", "label": ""])
            XCTFail("空の label が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("label must not be empty"),
                          error.localizedDescription)
        }
    }

    /// **省略可**は omit のヒントを添える(必須の "must not be empty" とは文言が違う)
    func testOmittableBundleIdEmptyStringGetsTheOmitHint() async {
        do {
            _ = try await server.call(tool: "ft_terminate", args: ["bundleId": ""])
            XCTFail("空の bundleId が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("bundleId must not be empty"), message)
            XCTAssertTrue(message.contains("omit it"), message)
        }
    }

    /// selector は既存の DSL 案内込みの文言を保つ(値域の表に載ってはいるが、この呼び口は
    /// 個別の文言を優先する)
    func testScrollToSelectorKeepsItsExistingWording() async {
        do {
            _ = try await server.call(tool: "ft_scroll_to", args: ["selector": ""])
            XCTFail("空の selector が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "selector is required (same syntax as the DSL: #id, a label, .type, a||b)"),
                error.localizedDescription)
        }
    }
}
