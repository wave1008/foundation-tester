import XCTest
@testable import FTDSL
import FTCore

/// DSL コマンドがドライバまで届く値の検証(記録ではなく**実際に発火した引数**を見る)。
/// press の duration はブリッジまで配線されていながらホスト側で 1.0 に潰れていた実績があるため、
/// 「DSL の引数がそのままドライバに届くこと」を型付き経路と合わせてここで固定する。
final class CommandDispatchTests: XCTestCase {

    /// #cleanup 1 要素だけを返し、tap/press の引数を記録するドライバ
    private final class RecordingDriver: AppDriver {
        private(set) var tapped: [Int] = []
        private(set) var pressed: [(ref: Int, duration: Double)] = []

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "cleanup", label: "片付け",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {
            pressed.append((ref, duration))
        }
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(driver: AppDriver) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-dispatch-test.json"),
                    emit: { _ in })
    }

    func testPressDurationReachesDriver() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    press("#cleanup")                    // 既定
                    press("#cleanup", duration: 2.5)     // 明示
                    press(.id("cleanup"), duration: 0.5) // 型付き
                }
            }
        }

        XCTAssertEqual(driver.pressed.map(\.duration),
                       [FlowStep.defaultPressDuration, 2.5, 0.5],
                       "DSL の duration がドライバまで届いていない")
    }

    /// 型付きセレクタが文字列版と同じ要素を実際に解決すること(等価性は SelTests、発火はここ)
    func testTypedSelectorResolvesSameElement() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    tap("#cleanup")
                    tap(.id("cleanup"))
                    tap(.type(.button).text("片付け"))
                }
            }
        }

        XCTAssertEqual(driver.tapped, [1, 1, 1])
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// 型付きセレクタはレポート・ヒールキャッシュのキーとして**記法の文字列**に戻る
    func testTypedSelectorIsRecordedAsExpression() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { tap(.id("cleanup")) }
            }
        }

        XCTAssertEqual(core.finalRecord.scenes.flatMap(\.steps).map(\.description),
                       ["tap \"#cleanup\""])
    }

    /// checked を報告しない要素(ただのボタン等)への isNotChecked は**何を書いても成功する**。
    /// notExist の id typo と同じ構造の穴なので、run 終了時の警告で気付けるようにする
    func testIsNotCheckedOnStatelessElementIsWarned() {
        let core = makeCore(driver: RecordingDriver())   // checked を返さない要素だけの画面
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                // XCTestCase.expectation と衝突するのでここでは action を使う(区分は本題でない)
                action { isNotChecked("#cleanup") }
            }
        }
        core.warnAboutNeverResolvedIDs()
        let messages = core.finalRecord.fixSuggestions.map(\.message)
        XCTAssertEqual(messages.contains { $0.contains("一度も checked 状態を観測していません") }, true,
                       "\(messages)")
    }

    /// scene 番号の重複は**警告する**(失敗にはしない = 既存シナリオを止めない)
    func testDuplicateSceneNumberIsWarned() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "最初") { action { tap("#cleanup") } }
            scene(1, "重複") { action { tap("#cleanup") } }
        }
        let messages = core.finalRecord.fixSuggestions.map(\.message)
        XCTAssertEqual(messages.contains { $0.contains("scene 1 が重複しています") }, true, "\(messages)")
        // 実行自体は止めない(2 scene とも記録される)
        XCTAssertEqual(core.finalRecord.scenes.count, 2)
    }
}
