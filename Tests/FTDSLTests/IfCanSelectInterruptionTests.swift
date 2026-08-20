// `ifCanSelect` が**宣言された割り込み**(irregularHandler)に阻まれたときの振る舞い(2026-08-20)。
//
// 覆われた要素は木から落ちる(別ウィンドウのモーダルを正しく扱った結果)ので、閉じずに
// 不成立を確定すると**分岐が黙って飛ぶ**。**失敗ではなく誤った経路**として現れるため、
// 落ちた場所は原因から遠くなり、しかも当の判定には注記が1つも残らない(受け手が実際に踏んだ形)。
//
// 契約は2つ: **①閉じてから見直す** ②**閉じた事実を判定の記録に残す**
// (「覆いを閉じたうえで無かった」と「覆われたまま無いことにした」は読み手にとって別物)。
// システム許可アラート版は IfCanSelectSystemAlertTests(同じ形・別の相手)。

import XCTest
@testable import FTDSL
import FTCore

final class IfCanSelectInterruptionTests: XCTestCase {

    private static func element(_ type: String, id: String? = nil, label: String?,
                                ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// アプリ内メッセージが覆っている間は**背面が木に居ない**(実機の in-app ブリッジと同じ)。
    /// 閉じるボタンを押すと背面が現れる
    private final class CoveredAppDriver: AppDriver, @unchecked Sendable {
        var covered = true
        /// 覆いを閉じても目的の要素は出てこない(陰性側の対照に使う)
        var targetEverAppears = true
        private(set) var tappedRefs: [Int] = []
        private(set) var snapshotCount = 0

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            let elements: [ElementInfo] = covered
                ? [element("other", id: "promo_modal", label: "カード登録へ", ref: 1),
                   element("button", id: "btn_promo_close", label: "閉じる", ref: 2)]
                : (targetEverAppears
                   ? [element("button", id: "tutorial_next", label: "いますぐ利用する", ref: 3)]
                   : [element("other", id: "home", label: "ホーム", ref: 4)])
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {
            tappedRefs.append(ref)
            if ref == 2 { covered = false }
        }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(_ driver: AppDriver,
                          emit: @escaping (ScenarioEvent) -> Void = { _ in }) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    systemAlertButtons: [],
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-ifcanselect-interruption-test.json"),
                    fallbackDriver: nil,
                    emit: emit)
    }

    /// 本命: 覆いを閉じたうえで見直し、**分岐が成立する**こと
    func test割り込みを閉じてから条件を見直す() {
        let driver = CoveredAppDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    ifCanSelect("いますぐ利用する") { ran = true }
                }
            }
        }

        XCTAssertEqual(driver.tappedRefs, [2], "閉じるボタンだけを押すこと")
        XCTAssertTrue(ran, "閉じた後に見直して成立させること(閉じただけで not met は無意味)")
    }

    /// **閉じた事実は判定の記録に残る**(不成立でも)。ここが無いと、覆いのせいで飛んだ分岐を
    /// 後から追えない —— 今回の不具合が気付かれなかった理由そのもの
    func test閉じたことは不成立でも記録に残る() {
        let driver = CoveredAppDriver()
        driver.targetEverAppears = false
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { event in
            if event.kind == "step" { steps.append(event) }
        }, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    ifCanSelect("いますぐ利用する") { ran = true }
                }
            }
        }

        XCTAssertFalse(ran, "本当に無いなら不成立のままでよい")
        guard let step = steps.first(where: { ($0.description ?? "").hasPrefix("ifCanSelect") }) else {
            return XCTFail("ifCanSelect のステップが記録されていない: \(steps.map { $0.description ?? "" })")
        }
        XCTAssertEqual(step.notes, [StepNote.interruptionDismissed.rawValue],
                       "機械可読な注記(run 横断で数える側)")
        XCTAssertTrue((step.description ?? "").contains("dismissed the interruption"),
                      "説明文にも残すこと: \(step.description ?? "")")
        XCTAssertEqual(step.status, "skipped", "不成立の記録の仕方は変えない")
    }

    /// 陰性対照: **宣言が無ければ何もしない**(閉じるための追加コストを払わない)
    func test宣言が無ければ触らない() {
        let driver = CoveredAppDriver()
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { event in
            if event.kind == "step" { steps.append(event) }
        }, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario { scene(1, "s") { action { ifCanSelect("いますぐ利用する") { ran = true } } } }

        XCTAssertTrue(driver.tappedRefs.isEmpty, "宣言していないのに押してはいけない")
        XCTAssertFalse(ran)
        XCTAssertNil(steps.first(where: { ($0.description ?? "").hasPrefix("ifCanSelect") })?.notes)
    }

    /// **最後の周回で閉じたのに不成立**でも注記は残る。ここを落とすと、
    /// 「もう出ないから終わった」のか「覆いを閉じたが対象は戻らなかった」のかが読めない
    func test繰り返しの最後に閉じた分も記録に残る() {
        let driver = CoveredAppDriver()
        // **1周目は割り込み無しで成立させる** —— 閉じるのを最後の周回だけにしないと、
        // 「成立した周回で拾った注記」が残ってしまい、最後の周回を落とす実装でも通る
        driver.covered = false
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { event in
            if event.kind == "step" { steps.append(event) }
        }, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    repeatWhileCanSelect("いますぐ利用する", max: 3) {
                        // 1周したら覆いが復活し、対象はもう戻らない(= 次の周回は
                        // 「閉じたが不成立」で終わる)
                        driver.covered = true
                        driver.targetEverAppears = false
                    }
                }
            }
        }

        guard let step = steps.first(where: {
            ($0.description ?? "").hasPrefix("repeatWhileCanSelect")
        }) else {
            return XCTFail("記録が無い: \(steps.map { $0.description ?? "" })")
        }
        XCTAssertEqual(step.notes, [StepNote.interruptionDismissed.rawValue],
                       "最後の周回で閉じた事実が落ちている: \(step.description ?? "")")
        XCTAssertTrue((step.description ?? "").contains("→ 1 time(s)"),
                      "回数の記録は変えない: \(step.description ?? "")")
    }

    /// `repeatWhileCanSelect` も同じ経路(判定は canSelect の1箇所)
    func test繰り返しの条件判定でも閉じる() {
        let driver = CoveredAppDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var rounds = 0
        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    repeatWhileCanSelect("いますぐ利用する", max: 1) { rounds += 1 }
                }
            }
        }

        XCTAssertEqual(driver.tappedRefs, [2])
        XCTAssertEqual(rounds, 1, "閉じた後に見直して1周は回ること")
    }
}
