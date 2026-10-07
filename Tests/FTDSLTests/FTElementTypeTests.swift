// 掴んだ要素からの入力 `select(…).type(text)`。自由関数 `type(selector, text)` と同じ経路(typeImpl)を通ること
// = 記録・デバイスへの呼び出し・失敗の文言・伏せ字化が同一であることを、2つの書き方を別々のコアで走らせて突き合わせる。

import XCTest
@testable import FTDSL
@testable import FTCore

final class FTElementTypeTests: XCTestCase {

    /// 入力欄1つ(`#login_id`)。打った値を保持して読み返しに返す(返さないと読み返しが追送・失敗に倒れる)
    private final class FieldDriver: AppDriver {
        private let state = LockedValue((value: "", log: [String]()))
        var calls: [String] { state.value.log }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            let current = state.value.value
            return SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [
                    ElementInfo(ref: 1, type: "textField", identifier: "login_id",
                                label: nil, value: current, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 100, width: 300, height: 40), depth: 0),
                ],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {
            state.withLock { $0.value += text; $0.log.append("type(\(ref.map(String.init) ?? "nil"), \(text))") }
        }
        func clearInput(ref: Int?) async throws {
            state.withLock { $0.value = ""; $0.log.append("clearInput(\(ref.map(String.init) ?? "nil"))") }
        }
        func swipe(_ direction: FTSwipeDirection) async throws {
            state.withLock { $0.log.append("swipe(\(direction.rawValue))") }
        }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private var project: URL!

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-element-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("dataset"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        SecretRedactor.shared.removeAll()
        try? FileManager.default.removeItem(at: project)
    }

    private struct Outcome {
        let steps: [DSLStepRecord]
        let calls: [String]
    }

    private func run(redact: Bool = false, _ body: @escaping () -> Void) -> Outcome {
        let driver = FieldDriver()
        let core = FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               visionClassifierProjectRoot: project, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-element-type-test.json"),
                               emit: { _ in })
        core.redactAccountValues = redact
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return Outcome(steps: core.finalRecord.scenes.flatMap(\.steps), calls: driver.calls)
    }

    private func typeStep(_ outcome: Outcome) -> DSLStepRecord? {
        outcome.steps.last { $0.description.hasPrefix("type") }
    }

    private func statusText(_ status: StepResult.Status) -> String { "\(status)" }

    /// 掴んだ要素からの type は自由関数の type と同じステップ(セレクタ・文字列・replace)を記録し、同じ呼び出しを撃つ
    func testChainedTypeRecordsTheSameStepAsTheFreeFunction() throws {
        for replace in [false, true] {
            let free = run { type("#login_id", "abc", replace: replace) }
            var returned: FTElement?
            let chained = run { returned = select("#login_id").type("abc", replace: replace) }

            let freeStep = try XCTUnwrap(typeStep(free))
            let chainedStep = try XCTUnwrap(typeStep(chained))
            XCTAssertEqual(chainedStep.description, freeStep.description, "replace=\(replace)")
            XCTAssertEqual(chainedStep.description,
                           "type \"#login_id\" \"abc\"" + (replace ? " (replace)" : ""))
            XCTAssertEqual(statusText(chainedStep.status), statusText(freeStep.status))
            XCTAssertEqual(statusText(chainedStep.status), statusText(.passed))
            XCTAssertEqual(chained.calls, free.calls, "replace=\(replace)")
            XCTAssertEqual(chained.calls.last, "type(1, abc)")
            XCTAssertEqual(chained.calls.contains("clearInput(1)"), replace)
            XCTAssertEqual(returned?.id, "login_id", "自由関数と同じく掴んだ要素を返す(検証を繋げられる)")
        }
    }

    /// `waitSeconds:` が解決の待ちに届く。**下限だけを測る**(負荷で伸びることはあっても縮まない)——
    /// 落とすと既定の再試行(約 0.7 秒)で諦めるので 1.2 秒に届かない
    func testChainedTypeForwardsWaitSeconds() throws {
        let started = Date()
        let outcome = run { select("#missing", waitSeconds: 0).type("abc", waitSeconds: 1.5) }
        let elapsed = Date().timeIntervalSince(started)
        let step = try XCTUnwrap(typeStep(outcome))
        guard case .failed = step.status else { return XCTFail("失敗していない: \(step.status)") }
        XCTAssertGreaterThanOrEqual(elapsed, 1.2, "waitSeconds: 1.5 を待たずに諦めた")
    }

    /// `scroll:` は持たないが `withScroll*` の文脈には従う(自由関数の `type(selector, text)` と同じ送り)
    func testChainedTypeFollowsTheWithScrollContext() throws {
        let free = run { withScrollDown { type("#missing", "abc", waitSeconds: 0) } }
        let chained = run {
            let element = select("#missing", waitSeconds: 0, scroll: .noScroll)
            withScrollDown { element.type("abc", waitSeconds: 0) }
        }
        let swipes = chained.calls.filter { $0.hasPrefix("swipe") }
        XCTAssertFalse(swipes.isEmpty, "withScrollDown の中で送らなかった: \(chained.calls)")
        XCTAssertEqual(swipes, free.calls.filter { $0.hasPrefix("swipe") })
    }

    /// 掴めなかった空の要素からは、自由関数と同じく解決の失敗(同じ文言)
    func testChainedTypeOnAnEmptyElementFailsLikeTheFreeFunction() throws {
        let free = run { type("#missing", "abc") }
        let chained = run { select("#missing", waitSeconds: 0).type("abc") }

        let freeStep = try XCTUnwrap(typeStep(free))
        let chainedStep = try XCTUnwrap(typeStep(chained))
        guard case .failed(let freeReason) = freeStep.status,
              case .failed(let chainedReason) = chainedStep.status else {
            return XCTFail("失敗していない: \(freeStep.status) / \(chainedStep.status)")
        }
        XCTAssertEqual(chainedReason, freeReason)
        XCTAssertEqual(chainedStep.description, freeStep.description)
        XCTAssertTrue(chained.calls.isEmpty, "\(chained.calls)")
    }

    /// 画像で掴んだ要素(見つかった・書けるセレクタあり / 見つからなかった)からは入力せずに失敗する
    func testTypeOnAnImageElementFailsWithoutTyping() throws {
        let found = FindImage.Match(
            element: ElementInfo(ref: 1, type: "textField", identifier: "login_id", label: nil, value: "",
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 100, width: 300, height: 40), depth: 0),
            visibleFrame: FTRect(x: 0, y: 100, width: 300, height: 40), distance: 0.01,
            template: URL(fileURLWithPath: "/tmp/logo.png"), selector: "#login_id")
        for match in [found, nil] {
            let outcome = run { FTElement(imageMatch: match, imageLabel: "logo").type("abc") }
            let step = try XCTUnwrap(typeStep(outcome))
            guard case .failed(let reason) = step.status else {
                return XCTFail("画像の要素へ入力できてしまった: \(step.status)")
            }
            XCTAssertEqual(reason,
                           "cannot type into an element found by image \"logo\"; tap it first and use type(text)")
            XCTAssertTrue(outcome.calls.isEmpty, "入力を撃った: \(outcome.calls)")
        }
    }

    /// 掴んだ要素からの入力でも account() の値の伏せ字化が効く(記録は伏せ、デバイスへは生の値)
    func testChainedTypeMasksAccountValues() throws {
        try #"{"[account1]": {"id": "alice-login", "password": "p@ssword-1"}}"#
            .write(to: project.appendingPathComponent("dataset/accounts.json"), atomically: true, encoding: .utf8)
        let outcome = run(redact: true) {
            select("#login_id").type(account("[account1].id"))
        }
        let step = try XCTUnwrap(typeStep(outcome))
        XCTAssertEqual(statusText(step.status), statusText(.passed))
        XCTAssertEqual(step.description, "type \"#login_id\" \"***\"")
        XCTAssertEqual(outcome.calls, ["type(1, alice-login)"], "デバイスへは生の値を送る")
    }
}
