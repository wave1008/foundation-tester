import XCTest
@testable import FTDSL
import FTCore

/// DSL コマンドがドライバまで届く値の検証(記録ではなく**実際に発火した引数**を見る)。
/// tap の holdSeconds はブリッジまで配線されていながらホスト側で 1.0 に潰れていた実績があるため、
/// 「DSL の引数がそのままドライバに届くこと」を型付き経路と合わせてここで固定する。
final class CommandDispatchTests: XCTestCase {

    /// #cleanup 1 要素だけを返し、tap/press の引数を記録するドライバ
    private final class RecordingDriver: AppDriver {
        private(set) var tapped: [Int] = []
        private(set) var pressed: [(ref: Int, duration: Double)] = []
        private(set) var pressEnterCount = 0
        /// exist が値を読むために追加のデバイス往復をしないことの確認用(1回の exist で 1 回のはず)
        private(set) var snapshotCount = 0

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            return SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "cleanup", label: "片付け",
                                       value: "1200", placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func pressEnter() async throws { pressEnterCount += 1 }
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {
            pressed.append((ref, duration))
        }
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}

        private(set) var homeCount = 0
        private(set) var appSwitcherCount = 0
        func home() async throws { homeCount += 1 }
        func openAppSwitcher() async throws { appSwitcherCount += 1 }
    }

    private func makeCore(driver: AppDriver, typeDriver: AppDriver? = nil) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-dispatch-test.json"),
                    typeDriver: typeDriver,
                    emit: { _ in })
    }

    /// hybrid(typeDriver あり = primary が in-app)では home/appSwitcher を **最初から**
    /// XCUITest 側へ出すこと。in-app は自プロセス外を触れず 501 になるため往復させない
    func testHomeAndAppSwitcherGoToXCUITestOnHybrid() {
        let primary = RecordingDriver()
        let xcui = RecordingDriver()
        let core = makeCore(driver: primary, typeDriver: xcui)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    home()
                    appSwitcher()
                }
            }
        }

        XCTAssertEqual([xcui.homeCount, xcui.appSwitcherCount], [1, 1],
                       "hybrid では XCUITest 側へ直行すべき")
        XCTAssertEqual([primary.homeCount, primary.appSwitcherCount], [0, 0],
                       "in-app 側は 501 になるだけなので撃ってはいけない")
    }

    /// typeDriver 無し(xcuitest / Android / inapp 単独)は従来どおり primary へ出すこと
    func testHomeAndAppSwitcherUsePrimaryWithoutTypeDriver() {
        let primary = RecordingDriver()
        let core = makeCore(driver: primary)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    home()
                    appSwitcher()
                }
            }
        }

        XCTAssertEqual([primary.homeCount, primary.appSwitcherCount], [1, 1])
    }

    func testTapHoldSecondsReachesDriver() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    tap("#cleanup", holdSeconds: 1.0)                    // 明示(旧既定相当)
                    tap("#cleanup", holdSeconds: 2.5)                    // 明示
                    tap(.id("cleanup"), holdSeconds: 0.5)                // 型付き
                }
            }
        }

        XCTAssertEqual(driver.pressed.map(\.duration), [1.0, 2.5, 0.5],
                       "DSL の holdSeconds がドライバまで届いていない")
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

    /// pressEnter はロケータを持たず、フォーカス中の要素へ直接 driver.pressEnter() が届くこと
    /// (StepExecutor のロケータ解決を経由しない経路。type(ref: nil) と同じ扱い)
    func testPressEnterReachesDriverAndIsRecorded() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { pressEnter() }
            }
        }

        XCTAssertEqual(driver.pressEnterCount, 1)
        XCTAssertEqual(core.finalRecord.scenes.flatMap(\.steps).map(\.description), ["pressEnter"])
        XCTAssertTrue(core.finalRecord.passed)
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
        XCTAssertEqual(messages.contains { $0.contains("a checked state was never observed") }, true,
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
        XCTAssertEqual(messages.contains { $0.contains("scene 1 is duplicated") }, true, "\(messages)")
        // 実行自体は止めない(2 scene とも記録される)
        XCTAssertEqual(core.finalRecord.scenes.count, 2)
    }

    /// exist が照合した要素の label/value/identifier が FTElement.text/value/id へ生で届くこと。
    /// 追加のデバイス往復は発生しない(exist 1 回につきスナップショット取得は 1 回のまま)
    func testExistExposesMatchedElementAttributes() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action { element = exist("#cleanup") }
            }
        }

        XCTAssertEqual(element.text, "片付け")
        XCTAssertEqual(element.value, "1200")
        XCTAssertEqual(element.id, "cleanup")
        // 読み出し自体も含め、追加のデバイス往復(スナップショット取得)を起こさない
        XCTAssertEqual(driver.snapshotCount, 1, "exist 1 回に対しスナップショットが複数回取られている")
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// select は exist と違い**検証として記録されない**(action: "select" であって assert: "exists"
    /// ではない)。record 上は description だけが見えるので "select ..." で判別する。
    /// 掴んだ要素の値も exist と同様に読め、tap/press は一切発火しない
    func testSelectRecordsAsActionAndExposesMatchedElementWithoutDeviceOperation() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action { element = select("#cleanup") }
            }
        }

        XCTAssertEqual(core.finalRecord.scenes.flatMap(\.steps).map(\.description),
                       ["select \"#cleanup\""], "select は検証(exist)ではなく操作として記録されること")
        XCTAssertEqual(element.text, "片付け")
        XCTAssertEqual(element.value, "1200")
        XCTAssertEqual(element.id, "cleanup")
        XCTAssertTrue(driver.tapped.isEmpty, "select はデバイス操作(tap)を呼んではいけない")
        XCTAssertTrue(driver.pressed.isEmpty, "select はデバイス操作(press)を呼んではいけない")
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// selectWithScrollDown が scroll: .down を同じステップに畳んで積むこと(tap(scroll:)/exist(scroll:)
    /// と同じ規約。別の scrollTo ステップに分かれないことも合わせて確認)
    func testSelectWithScrollDownCarriesScrollInSameStep() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { selectWithScrollDown("#cleanup") }
            }
        }

        XCTAssertEqual(core.finalRecord.scenes.flatMap(\.steps).map(\.description),
                       ["select \"#cleanup\""],
                       "scroll 探索は別ステップを増やさず1行のまま記録されること")
    }

    /// select(optional: true) は見つからない要素でも失敗にせずスキップすること
    func testSelectOptionalSkipsWhenElementMissing() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action { element = select("#missing", optional: true, timeout: 0) }
            }
        }

        XCTAssertNil(element.text, "見つからなければ matched は無いはず")
        XCTAssertTrue(core.finalRecord.passed, "optional の未検出はシナリオを失敗させない")
    }
}
