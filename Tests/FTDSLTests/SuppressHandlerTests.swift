// `suppressHandler { }` / `useHandler { }`(Shirates 準拠の名前)の契約。
//
// **シナリオ自身がそのモーダルを検証・操作したい**とき、宣言済みハンドラが先に閉じてしまう。
// これが無いと「`irregularHandler` を宣言する場所をずらす」回避策になる(自前 E2E も
// scene 15 でそうしていた)。
//
// 契約:
//   ①抑止中は閉じない ②ブロックを出たら戻る(失敗しても戻る) ③入れ子で一時的に戻せる
//   ④**抑止したまま落ちた**ときだけ注記に出す(抑止の危険は「抑止したまま忘れる」)
//
// **止まるのは「ツールが閉じること」だけ**: 割り込みが出ること自体はアプリの都合で、
// 抑止しても「送った操作が吸われる」形は変わらない(責務は docs/commands.md の表)。

import XCTest
@testable import FTDSL
import FTCore

final class SuppressHandlerTests: XCTestCase {

    private final class ModalDriver: AppDriver, @unchecked Sendable {
        private(set) var tappedRefs: [Int] = []
        var modalShown = true

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            func element(_ ref: Int, _ id: String, _ y: Double) -> ElementInfo {
                ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: y, width: 100, height: 40), depth: 0)
            }
            var elements = [element(1, "target", 0)]
            if modalShown {
                elements.append(element(2, "promo_modal", 100))
                elements.append(element(3, "btn_promo_close", 200))
            }
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {
            tappedRefs.append(ref)
            if ref == 3 { modalShown = false }
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
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-suppress-handler-test.json"),
                    fallbackDriver: nil, emit: emit)
    }

    /// 本命: 抑止中は閉じない(シナリオが自分で検証・操作できる)
    func test抑止中は閉じない() {
        let driver = ModalDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler {
                        exist("#promo_modal")     // 閉じられていたらここが落ちる
                        tap("#target")
                    }
                }
            }
        }

        XCTAssertEqual(driver.tappedRefs, [1], "閉じるボタン(ref 3)を押してはいけない")
        XCTAssertTrue(driver.modalShown, "抑止中にモーダルが消えている")
    }

    /// ブロックを出たら元に戻る
    func testブロックを出たら閉じる() {
        let driver = ModalDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler { exist("#promo_modal") }
                    tap("#target")                // ここでは閉じる
                }
            }
        }

        XCTAssertTrue(driver.tappedRefs.contains(3), "ブロックを出たのに閉じていない")
        XCTAssertFalse(driver.modalShown)
    }

    /// 入れ子で一時的に戻せる
    func test内側のuseHandlerで戻せる() {
        let driver = ModalDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler {
                        exist("#promo_modal")
                        useHandler { tap("#target") }   // ここだけ従来どおり閉じる
                    }
                }
            }
        }

        XCTAssertTrue(driver.tappedRefs.contains(3))
    }

    /// **抑止したまま落ちた**ときだけ注記に出す(成功しているステップには出さない)
    func test抑止中に落ちたら注記に出る() {
        let driver = ModalDriver()
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { event in
            if event.kind == "step" { steps.append(event) }
        }, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler {
                        tap("#no_such_element", timeout: 0)
                    }
                }
            }
        }

        let failed = steps.filter { $0.status == "failed" }
        guard let step = failed.first else { return XCTFail("失敗ステップが無い") }
        XCTAssertTrue((step.detail ?? "").contains("suppressed")
                          || (step.description ?? "").contains("suppressed"),
                      "抑止中だったことが読めない: \(step.description ?? "") / \(step.detail ?? "")")
    }

    /// **ステップを跨いで引きずらない**。抑止区間で割り込みを見たことが、
    /// 区間を出た後の失敗にまで付くと「抑止中だった」が嘘になる
    func test抑止区間を出た後の失敗には出さない() {
        let driver = ModalDriver()
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { event in
            if event.kind == "step" { steps.append(event) }
        }, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler { exist("#promo_modal") }   // ここで「見た」
                    tap("#no_such_element", timeout: 0)         // 区間の外で落ちる
                }
            }
        }

        let failed = steps.filter { $0.status == "failed" }
        guard let step = failed.first else { return XCTFail("失敗ステップが無い") }
        XCTAssertFalse((step.description ?? "").contains("suppressed"),
                       "抑止区間の外なのに『抑止中だった』と言っている: \(step.description ?? "")")
    }

    // MARK: - CAE を跨ぐ制御(disableHandler / enableHandler)

    /// **本命**: `condition` で止めて `expectation` で戻す。
    /// `suppressHandler { }` は1つのブロックの内側にしか置けないので、この形は命令形でしか書けない
    func testCAEを跨いで止めて戻せる() {
        let driver = ModalDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                condition {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    disableHandler()
                    exist("#promo_modal")        // 止まっているので閉じられない
                }.action {
                    tap("#target")               // ブロックを跨いでも止まったまま
                }.expectation {
                    exist("#promo_modal")
                    enableHandler()
                    tap("#target")               // ここで閉じる
                }
            }
        }

        // **順序で見る**: 「閉じた回数」だけだと、止まっていない実装
        // (= 最初の exist で閉じて落ちる)でも ref 3 は現れるので判定にならない。
        // 止まっていれば target(1)を先に叩き、閉じる(3)のは enableHandler の後になる
        XCTAssertEqual(driver.tappedRefs, [1, 3, 1],
                       "target → (enable 後に)閉じる → target、の順にならない: \(driver.tappedRefs)")
    }

    /// `useHandler { }` は命令形の抑止も一時的に戻す(内側だけ従来どおり閉じる)
    func testuseHandlerはdisableHandlerも一時的に戻す() {
        let driver = ModalDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    disableHandler()
                    useHandler { tap("#target") }
                }
            }
        }

        XCTAssertTrue(driver.tappedRefs.contains(3), "useHandler の中で閉じていない")
    }

    /// `enableHandler()` はブロック形の抑止までは解除しない
    /// (ブロックは出口で必ず戻るので、内側から外すと入れ子の意味が壊れる)
    func testenableHandlerはブロック形を解除しない() {
        let driver = ModalDriver()
        FTRuntime.bootstrap(core: makeCore(driver), dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler {
                        enableHandler()
                        tap("#target")
                    }
                }
            }
        }

        XCTAssertFalse(driver.tappedRefs.contains(3), "ブロック形の抑止が解除されている")
        XCTAssertTrue(driver.modalShown)
    }

    /// 陰性対照: 成功したステップには出さない(正常な使い方の出力を増やさない)
    func test成功したステップには出さない() {
        let driver = ModalDriver()
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { event in
            if event.kind == "step" { steps.append(event) }
        }, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
                    suppressHandler { tap("#target") }
                }
            }
        }

        XCTAssertFalse(steps.contains { ($0.description ?? "").contains("suppressed") },
                       "成功しているのに注記が出ている")
    }
}
