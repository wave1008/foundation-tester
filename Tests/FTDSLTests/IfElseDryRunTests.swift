// dry-run は `ifCanSelect` の**両方のブロック**(成立側と `.ifElse`)を列挙する。
// dry-run の canSelect は常に成立なので、else 側を飛ばすと中のセレクタ構文誤り・台帳に無い `#id` が
// デバイス実行まで出てこない(3段検証「誤りは早い段の言葉で返す」に反する)。
// デバイス実行は従来どおり(成立側が走ったら else は未実行)。

import XCTest
@testable import FTDSL
import FTCore

final class IfElseDryRunTests: XCTestCase {

    /// 常に 1 要素(#field)を返す
    private final class StubDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "field", label: nil,
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(dryRun: Bool) -> FTDriveCore {
        FTDriveCore(driver: StubDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: dryRun,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-ifelse-dryrun-test.json"),
                    emit: { _ in })
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] {
        core.finalRecord.scenes.flatMap(\.steps)
    }

    private func isFailed(_ status: StepResult.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// 本命: `.ifElse` の中の構文誤りは dry-run で落ちる
    func testDryRunEnumeratesTheElseBlock() {
        let core = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var elseRan = false
        scenario {
            scene(1, "s") {
                action {
                    ifCanSelect("#field") { tap("#field") }
                        .ifElse {
                            elseRan = true
                            tap(".Button:near(合計)")   // 未知の記法
                        }
                }
            }
        }

        XCTAssertTrue(elseRan, "dry-run で else 側が列挙されていない")
        let recorded = steps(core)
        XCTAssertEqual(recorded.map(\.description).filter { $0.hasPrefix("ifCanSelect") }.count, 1)
        XCTAssertTrue(recorded.contains { $0.description.contains("near(合計)") && isFailed($0.status) },
                      "else 側の構文誤りが dry-run を素通りした: \(recorded.map(\.description))")
    }

    /// デバイス実行は従来どおり: 成立側が走ったら else は実行しない
    func testDeviceRunStillSkipsTheElseBlockWhenTaken() {
        let core = makeCore(dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var mainRan = false
        var elseRan = false
        scenario {
            scene(1, "s") {
                action {
                    ifCanSelect("#field") { mainRan = true }
                        .ifElse { elseRan = true }
                }
            }
        }

        XCTAssertTrue(mainRan)
        XCTAssertFalse(elseRan, "成立しているのに else が走った")
    }

    /// デバイス実行の不成立側も従来どおり(else が走る)
    func testDeviceRunRunsTheElseBlockWhenNotMet() {
        let core = makeCore(dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var mainRan = false
        var elseRan = false
        scenario {
            scene(1, "s") {
                action {
                    ifCanSelect("#missing") { mainRan = true }
                        .ifElse { elseRan = true }
                }
            }
        }

        XCTAssertFalse(mainRan)
        XCTAssertTrue(elseRan)
    }

    /// 「アサーションが無い」の判定: dry-run は両側を見たので、**両側とも検証が無ければ警告する**
    /// (デバイス実行では else が未実行 = 黙る。AuthoringGuardTests の対称)
    func testDryRunCountsAssertionsFromBothBranches() {
        let silent = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: silent, dslThread: Thread.current)
        scenario {
            scene(1, "else に検証がある") {
                action { tap("#field") }
                    .expectation {
                        ifCanSelect("#field") { tap("#field") }
                            .ifElse { exist("#field") }
                    }
            }
        }
        FTRuntime.tearDown()
        XCTAssertFalse(silent.finalRecord.fixSuggestions.contains { $0.message.contains("no assertions") },
                       "else 側の検証が数えられていない")

        let warned = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: warned, dslThread: Thread.current)
        scenario {
            scene(1, "両側とも検証が無い") {
                action { tap("#field") }
                    .expectation {
                        ifCanSelect("#field") { tap("#field") }
                            .ifElse { tap("#field") }
                    }
            }
        }
        FTRuntime.tearDown()
        XCTAssertTrue(warned.finalRecord.fixSuggestions.contains { $0.message.contains("contains no assertions") },
                      "両側を列挙したのに、検証の無い expectation を黙って通した")
    }
}
