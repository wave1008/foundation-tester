import XCTest
@testable import FTDSL
import FTCore

/// DSL コマンドがドライバまで届く値の検証(記録ではなく**実際に発火した引数**を見る)。
/// tap の holdSeconds はブリッジまで配線されていながらホスト側で 1.0 に潰れていた実績があるため、
/// 「DSL の引数がそのままドライバに届くこと」を型付き経路と合わせてここで固定する。
final class CommandDispatchTests: XCTestCase {

    /// #cleanup と #nolabel を返し、tap/press の引数を記録するドライバ
    private final class RecordingDriver: AppDriver {
        private(set) var tapped: [Int] = []
        private(set) var pressed: [(ref: Int, duration: Double)] = []
        private(set) var pressEnterCount = 0
        /// exist が値を読むために追加のデバイス往復をしないことの確認用(1回の exist で 1 回のはず)
        private(set) var snapshotCount = 0
        private(set) var installedPaths: [String] = []
        private(set) var screenshotCount = 0
        /// installApp/screenshot のテストで使う固定値
        var fixedScreenshotData = Data([0xAA, 0xBB])
        private(set) var uninstalledIDs: [String] = []
        /// isAppForeground の呼び出し順ごとの応答(尽きたら最後を繰り返す。空なら常に false)。
        /// appIs のポーリング検証用(ScriptedDriver と同じ規約)
        var foregroundMatches: [Bool] = []
        private(set) var isAppForegroundQueried: [String] = []
        private(set) var isAppForegroundCallCount = 0
        /// foregroundAppID() の固定応答。既定 nil(iOS の「取得手段が無い」を模す)
        var foregroundAppIDValue: String?

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws { installedPaths.append(packagePath) }
        func uninstall(bundleID: String) async throws { uninstalledIDs.append(bundleID) }
        func isAppForeground(bundleID: String) async throws -> Bool {
            isAppForegroundQueried.append(bundleID)
            defer { isAppForegroundCallCount += 1 }
            guard !foregroundMatches.isEmpty else { return false }
            let index = min(isAppForegroundCallCount, foregroundMatches.count - 1)
            return foregroundMatches[index]
        }
        func foregroundAppID() async throws -> String? { foregroundAppIDValue }
        private(set) var launchedBundleIDs: [String] = []
        private(set) var openURLCalls: [(url: String, bundleID: String?)] = []
        func launch(bundleID: String) async throws { launchedBundleIDs.append(bundleID) }
        func openURL(_ url: String, bundleID: String?) async throws {
            openURLCalls.append((url, bundleID))
        }
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            return SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "cleanup", label: "片付け",
                                       value: "1200", placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0),
                           // label を持たない要素(isEmpty が .text の有無と別物であることの検証用)
                           ElementInfo(ref: 2, type: "other", identifier: "nolabel", label: nil,
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 20, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func pressEnter() async throws { pressEnterCount += 1 }
        func swipe(_ direction: FTSwipeDirection) async throws {}
        /// flick/swipePointToPoint 系の到達点記録用(AppDriver の既定実装は 501 を投げるだけなので上書きする)
        private(set) var dragCalls: [(fromX: Double, fromY: Double, toX: Double, toY: Double,
                                      pressSeconds: Double, durationSeconds: Double)] = []
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                  pressSeconds: Double, durationSeconds: Double) async throws {
            dragCalls.append((fromX, fromY, toX, toY, pressSeconds, durationSeconds))
        }
        func press(ref: Int, duration: Double) async throws {
            pressed.append((ref, duration))
        }
        func screenshot() async throws -> Data { screenshotCount += 1; return fixedScreenshotData }
        func terminate() async throws {}

        private(set) var homeCount = 0
        private(set) var appSwitcherCount = 0
        func home() async throws { homeCount += 1 }
        func openAppSwitcher() async throws { appSwitcherCount += 1 }
    }

    private func makeCore(driver: AppDriver, typeDriver: AppDriver? = nil,
                          fallbackDriver: AppDriver? = nil,
                          platform: String = "ios",
                          emit: @escaping (ScenarioEvent) -> Void = { _ in }) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: platform, app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-dispatch-test.json"),
                    fallbackDriver: fallbackDriver, typeDriver: typeDriver,
                    emit: emit)
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

    /// checked を報告しない要素(ただのボタン等)への checkIsOFF は**何を書いても成功する**。
    /// notExist の id typo と同じ構造の穴なので、run 終了時の警告で気付けるようにする
    func testIsNotCheckedOnStatelessElementIsWarned() {
        let core = makeCore(driver: RecordingDriver())   // checked を返さない要素だけの画面
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                // XCTestCase.expectation と衝突するのでここでは action を使う(区分は本題でない)
                action { select("#cleanup").checkIsOFF() }
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
        XCTAssertFalse(element.isEmpty, "掴めていれば isEmpty は false")
        XCTAssertTrue(element.isNotEmpty)
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

    /// **select は掴めなくても空要素を返し、シナリオを止めない**(`optional:` 廃止後の唯一の契約)。
    /// ここが失敗に転ぶと `.isEmpty` 分岐を書いた利用者コードが到達しなくなる
    func testSelectReturnsEmptyElementWhenMissing() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        var reachedNextStep = false
        scenario {
            scene(1, "s") {
                action {
                    element = select("#missing", timeout: 0)
                    reachedNextStep = true
                }
            }
        }

        XCTAssertNil(element.text, "見つからなければ matched は無いはず")
        XCTAssertTrue(element.isEmpty, "掴めていなければ isEmpty は true")
        XCTAssertFalse(element.isNotEmpty)
        XCTAssertTrue(reachedNextStep, "select の空振りは後続を止めないこと")
        XCTAssertTrue(core.finalRecord.passed, "select の未検出はシナリオを失敗させない")
    }

    /// **`wait` に負値を渡してもプロセスを落とさない**(`UInt64(負の Double)` は trap する)。
    /// 1プロセス=1シナリオなので crash するとレポートごと消える(design.md §10)。
    /// このテストは「落ちないこと」自体が assertion で、trap すれば実行プロセスごと死ぬ
    func testNegativeWaitDoesNotCrashTheProcess() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        // XCTestCase.wait(for:) と名前が衝突するのでモジュール修飾する(実シナリオは
        // XCTestCase を継承しないので素の wait(...) で書ける)
        scenario { scene(1, "s") { action { FTDSL.wait(-1) } } }

        XCTAssertTrue(core.finalRecord.passed, "負値は 0 に丸めて素通りすること")
    }

    /// **上限側も trap する**(`UInt64(無限大)` / UInt64 に収まらない巨大値)。
    /// 壁時計上限(FTSync.commandTimeout)へ丸める — それより長くは待てない契約なので
    /// 情報は失われない(docs/commands.md「1コマンドの壁時計上限は 120 秒」)
    func testHugeWaitIsClampedInsteadOfTrapping() {
        XCTAssertEqual(ftSleepNanoseconds(.infinity),
                       UInt64(FTSync.commandTimeout * 1_000_000_000))
        XCTAssertEqual(ftSleepNanoseconds(1e30), UInt64(FTSync.commandTimeout * 1_000_000_000))
        XCTAssertEqual(ftSleepNanoseconds(.nan), 0, "NaN は 0 に落ちること")
        XCTAssertEqual(ftSleepNanoseconds(-1), 0)
        XCTAssertEqual(ftSleepNanoseconds(1.5), 1_500_000_000, "正常値は素通しすること")
    }

    /// 同型: `doUntilTrue(intervalSeconds:)` の負値も trap しない
    func testNegativeIntervalDoesNotCrashTheProcess() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var attempts = 0
        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("状態待ち", waitSeconds: 1, intervalSeconds: -0.5) {
                        attempts += 1
                        return attempts >= 2
                    }
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertGreaterThanOrEqual(attempts, 2, "負の間隔でも繰り返せること")
    }

    /// 対の検証: **tap は掴めなければ失敗**してシナリオを中断する。
    /// `optional:` の廃止で「空振りを黙って許す」経路が操作系に残っていないことを固定する
    func testTapFailsAndAbortsWhenElementMissing() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var reachedNextStep = false
        scenario {
            scene(1, "s") {
                action {
                    tap("#missing", timeout: 0)
                    reachedNextStep = true
                }
            }
        }

        XCTAssertFalse(core.finalRecord.passed, "tap の未検出はシナリオを失敗させること")
        XCTAssertTrue(reachedNextStep, "ブロック内の生 Swift コードはスキップされない(既知の契約)")
    }

    /// isEmpty は matched の有無で判定する。**`.text == nil` では代用できない**
    /// (label を持たない要素を掴んだときに「空」と誤判定するため)
    func testIsEmptyDistinguishesUnmatchedFromLabellessElement() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action { element = select("#nolabel") }
            }
        }

        XCTAssertNil(element.text, "この要素は label を持たない")
        XCTAssertFalse(element.isEmpty, "label が無くても掴めていれば空ではない")
        XCTAssertEqual(element.id, "nolabel")
    }

    // MARK: - waitForDisplay / waitForClose

    /// waitSeconds が step.timeout として実際に効くこと(既定 15s ではなく明示値でタイムアウトする)。
    /// 要素が見つからない状態を短い waitSeconds で待たせ、既定値よりずっと早く失敗することで確認する
    func testWaitForDisplayUsesWaitSecondsAsTimeout() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let start = Date()
        scenario {
            scene(1, "s") {
                action { waitForDisplay("#missing", waitSeconds: 0.3) }
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(core.finalRecord.passed, "見つからない要素は失敗すること")
        XCTAssertLessThan(elapsed, 1.0, "既定の 15s ではなく明示した waitSeconds(0.3s)で失敗していない(実測 \(elapsed)s)")
    }

    /// 対の検証: waitForClose も waitSeconds を timeout として使うこと(消えない要素を短時間で見切る)
    func testWaitForCloseUsesWaitSecondsAsTimeout() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let start = Date()
        scenario {
            scene(1, "s") {
                action { waitForClose("#cleanup", waitSeconds: 0.3) }
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(core.finalRecord.passed, "消えない要素は失敗すること")
        XCTAssertLessThan(elapsed, 1.0, "既定の 15s ではなく明示した waitSeconds(0.3s)で失敗していない(実測 \(elapsed)s)")
    }

    /// waitForDisplay の素直な成功経路: exist と同様に照合済み要素を返す
    func testWaitForDisplayHappyPathReturnsMatchedElement() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action { element = waitForDisplay("#cleanup") }
            }
        }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(element.text, "片付け")
        XCTAssertEqual(element.id, "cleanup")
    }

    /// waitForClose の素直な成功経路: 最初から不在なら即成功する
    func testWaitForCloseHappyPathPassesWhenAlreadyAbsent() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { waitForClose("#missing") }
            }
        }

        XCTAssertTrue(core.finalRecord.passed)
    }

    // MARK: - installApp

    func testInstallAppForwardsResolvedPathToDriver() throws {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-install-test-\(UUID().uuidString).app")
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        scenario {
            scene(1, "s") {
                action { installApp(path.path) }
            }
        }

        XCTAssertEqual(driver.installedPaths, [path.path])
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// `~` 始まりのパスが展開されてから存在確認・install に渡ること
    func testInstallAppExpandsTildeInPath() throws {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let home = NSHomeDirectory()
        let relative = "ft-install-tilde-test-\(UUID().uuidString).app"
        let expanded = URL(fileURLWithPath: home).appendingPathComponent(relative)
        try Data().write(to: expanded)
        defer { try? FileManager.default.removeItem(at: expanded) }

        scenario {
            scene(1, "s") {
                action { installApp("~/\(relative)") }
            }
        }

        XCTAssertEqual(driver.installedPaths, [expanded.path])
        XCTAssertTrue(core.finalRecord.passed)
    }

    func testInstallAppFailsWhenPathDoesNotExist() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { installApp("/definitely/not/a/real/path.app") }
            }
        }

        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertTrue(driver.installedPaths.isEmpty)
        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertTrue(reason.contains("not found"), reason)
    }

    /// 引数省略時は解決手段が無い明示エラーになること(実行プロファイルの appPath は
    /// orchestrator 止まりでシナリオサブプロセスへ渡らないため)
    func testInstallAppFailsWhenPathIsNilAndCannotBeResolved() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { installApp() }
            }
        }

        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertTrue(driver.installedPaths.isEmpty)
        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertTrue(reason.contains("cannot be resolved automatically"), reason)
    }

    /// installControl が無いホスト無し単独実行でも、親が解決した appPath(--app-path)があれば
    /// 引数省略時にそれを使う(installControl がある場合の RPC 経路より優先度は低い。
    /// 両方無いケースは testInstallAppFailsWhenPathIsNilAndCannotBeResolved で確認済み)
    func testInstallAppUsesAppPathOverrideWhenArgumentOmitted() throws {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-install-override-test-\(UUID().uuidString).app")
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        core.appPathOverride = path.path
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { installApp() }
            }
        }

        XCTAssertEqual(driver.installedPaths, [path.path])
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// installControl がある(オーケストレータ配下)ときは、子は driver.install を直接呼ばず
    /// installRequest を emit してブロックし、親の応答(installResult 相当)で完了する。
    /// installApp() は performCustom の body(FTSync 経由の detached Task)内で実行されるため、
    /// DSL 呼び出し自体は別スレッドで走らせ、このテストスレッドが installRequest を観測してから
    /// resolve する(実プロセス間通信は使わない — ScenarioInstallControl の直接呼び出しで代替)
    func testInstallAppRoutesThroughInstallControlAndAppliesSuccess() async throws {
        let driver = RecordingDriver()
        let installControl = ScenarioInstallControl()
        let eventsLock = NSLock()
        var events: [ScenarioEvent] = []
        let core = makeCore(driver: driver, emit: { event in
            eventsLock.lock(); events.append(event); eventsLock.unlock()
        })
        core.installControl = installControl

        let done = DispatchSemaphore(value: 0)
        let runner = Thread {
            scenario {
                scene(1, "s") {
                    action { installApp() }
                }
            }
            done.signal()
        }
        // installApp() は RPC 待ちでブロックするため専用スレッドで走らせる。dslThread は
        // 実際に scenario {} を実行するスレッド(runner)を指す必要がある(このテストスレッドを
        // 指すと FTRuntime.requireCore がスレッド違反とみなし、installApp() 自体が走らない)
        FTRuntime.bootstrap(core: core, dslThread: runner)
        runner.start()

        var requestID: Int?
        let deadline = Date().addingTimeInterval(5)
        while requestID == nil, Date() < deadline {
            eventsLock.lock()
            requestID = events.first(where: { $0.kind == "installRequest" })?.requestID
            eventsLock.unlock()
            if requestID == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard let requestID else { return XCTFail("installRequest イベントが届かなかった") }

        let resolved = expectation(description: "installResult applied")
        Task {
            await installControl.resolve(id: requestID, ok: true,
                                         message: "the in-app bridge will be reinjected")
            resolved.fulfill()
        }
        await fulfillment(of: [resolved], timeout: 5)

        guard done.wait(timeout: .now() + 5) == .success else {
            return XCTFail("installApp() が RPC 応答後も完了しなかった")
        }
        FTRuntime.tearDown()

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertTrue(driver.installedPaths.isEmpty,
                      "実行は親側の責務なので子の driver.install は呼ばれない")
        eventsLock.lock()
        let request = events.first(where: { $0.kind == "installRequest" })
        let hasNote = events.contains {
            $0.kind == "log" && ($0.message?.contains("reinjected") ?? false)
        }
        eventsLock.unlock()
        XCTAssertEqual(request?.scenario, "T.S0010")
        XCTAssertNil(request?.installPath, "引数省略なら installPath は nil のまま親へ渡す")
        XCTAssertTrue(hasNote, "親からの注記(in-app 再注入)がログとして残るはず")
    }

    /// 親が ok:false を返したら、その message が失敗理由になる(明示エラーではなく親由来の理由)
    func testInstallAppRoutesThroughInstallControlAndSurfacesFailure() async throws {
        let driver = RecordingDriver()
        let installControl = ScenarioInstallControl()
        let eventsLock = NSLock()
        var events: [ScenarioEvent] = []
        let core = makeCore(driver: driver, emit: { event in
            eventsLock.lock(); events.append(event); eventsLock.unlock()
        })
        core.installControl = installControl

        let done = DispatchSemaphore(value: 0)
        let runner = Thread {
            scenario {
                scene(1, "s") {
                    action { installApp("/explicit/App.app") }
                }
            }
            done.signal()
        }
        // dslThread は runner を指す(理由は success 版のコメント参照)
        FTRuntime.bootstrap(core: core, dslThread: runner)
        runner.start()

        var requestID: Int?
        let deadline = Date().addingTimeInterval(5)
        while requestID == nil, Date() < deadline {
            eventsLock.lock()
            requestID = events.first(where: { $0.kind == "installRequest" })?.requestID
            eventsLock.unlock()
            if requestID == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard let requestID else { return XCTFail("installRequest イベントが届かなかった") }

        let resolved = expectation(description: "installResult applied")
        Task {
            await installControl.resolve(id: requestID, ok: false, message: "package not found")
            resolved.fulfill()
        }
        await fulfillment(of: [resolved], timeout: 5)

        guard done.wait(timeout: .now() + 5) == .success else {
            return XCTFail("installApp() が RPC 応答後も完了しなかった")
        }
        FTRuntime.tearDown()

        XCTAssertFalse(core.finalRecord.passed)
        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertEqual(reason, "package not found")
        eventsLock.lock()
        let request = events.first(where: { $0.kind == "installRequest" })
        eventsLock.unlock()
        XCTAssertEqual(request?.installPath, "/explicit/App.app")
    }

    // MARK: - screenshot

    func testScreenshotCallsDriverAndAttachesDataToItsStep() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { screenshot() }
            }
        }

        XCTAssertEqual(driver.screenshotCount, 1)
        let step = core.finalRecord.scenes.flatMap(\.steps)[0]
        XCTAssertEqual(step.screenshotData, driver.fixedScreenshotData)
        XCTAssertEqual(step.screenshotLabel, "1.png", "ファイル名省略時はステップ連番+.png")
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// 明示したファイル名は .png を補って label になること
    func testScreenshotUsesExplicitFilename() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { screenshot(filename: "before-tap") }
            }
        }

        let step = core.finalRecord.scenes.flatMap(\.steps)[0]
        XCTAssertEqual(step.screenshotLabel, "before-tap.png")
    }

    /// 通常の tap 等はステップに screenshotData を持たないこと(screenshot 専用の経路であることの固定)
    func testNonScreenshotStepsHaveNoScreenshotData() {
        let core = makeCore(driver: RecordingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { tap("#cleanup") }
            }
        }

        XCTAssertNil(core.finalRecord.scenes.flatMap(\.steps)[0].screenshotData)
    }

    // MARK: - launchApp / openURL

    /// url なしの launchApp は従来どおり launch(bundleID:) だけを呼び、openURL は一切呼ばないこと
    /// (「url が nil のときの挙動は1バイトも変えない」契約)
    func testLaunchAppWithoutURLDoesNotCallOpenURL() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { launchApp() }
            }
        }

        XCTAssertEqual(driver.launchedBundleIDs, ["com.example.app"])
        XCTAssertTrue(driver.openURLCalls.isEmpty)
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// url ありの launchApp は launch → openURL の順で1ステップとして実行すること
    func testLaunchAppWithURLLaunchesThenDeliversURL() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { launchApp(url: "fte2e://screen/detail") }
            }
        }

        XCTAssertEqual(driver.launchedBundleIDs, ["com.example.app"])
        XCTAssertEqual(driver.openURLCalls.count, 1)
        XCTAssertEqual(driver.openURLCalls.first?.url, "fte2e://screen/detail")
        XCTAssertEqual(driver.openURLCalls.first?.bundleID, "com.example.app")
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// bundleID を明示したときは launch/openURL の両方がその bundleID を使うこと(既定 app とは別物)
    func testLaunchAppWithBundleIDAndURLUsesGivenBundleForBoth() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { launchApp("com.other.app", url: "fte2e://screen/detail") }
            }
        }

        XCTAssertEqual(driver.launchedBundleIDs, ["com.other.app"])
        XCTAssertEqual(driver.openURLCalls.first?.bundleID, "com.other.app")
    }

    /// openURL() 単独は core.appBundleID を宛先にドライバへ届くこと(launch は呼ばない)
    func testOpenURLAloneForwardsAppBundleIDToDriver() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { openURL("fte2e://screen/detail") }
            }
        }

        XCTAssertTrue(driver.launchedBundleIDs.isEmpty)
        XCTAssertEqual(driver.openURLCalls.count, 1)
        XCTAssertEqual(driver.openURLCalls.first?.url, "fte2e://screen/detail")
        XCTAssertEqual(driver.openURLCalls.first?.bundleID, "com.example.app")
        XCTAssertTrue(core.finalRecord.passed)
    }

    // MARK: - removeApp

    func testRemoveAppForwardsGivenBundleIDToDriver() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { removeApp("com.other.app") }
            }
        }

        XCTAssertEqual(driver.uninstalledIDs, ["com.other.app"])
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// 引数省略時は launchApp() 引数なしと同じ既定 bundleID(core.appBundleID)を使うこと
    func testRemoveAppUsesAppBundleIDWhenArgumentOmitted() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { removeApp() }
            }
        }

        XCTAssertEqual(driver.uninstalledIDs, ["com.example.app"])
    }

    // MARK: - appIs

    func testAppIsPassesImmediatelyWhenAlreadyForeground() {
        let driver = RecordingDriver()
        driver.foregroundMatches = [true]
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { appIs("com.example.app", waitSeconds: 0.3) }
            }
        }

        XCTAssertEqual(driver.isAppForegroundQueried, ["com.example.app"])
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// iOS(foregroundAppID が nil を返す)では、失敗メッセージに actual= を含めないこと
    func testAppIsTimesOutWithoutActualOnIOS() {
        let driver = RecordingDriver()
        // foregroundMatches 空 = 常に false
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { appIs("com.example.app", waitSeconds: 0.3) }
            }
        }

        XCTAssertFalse(core.finalRecord.passed)
        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertFalse(reason.contains("actual="), reason)
    }

    /// ポーリング挙動: 最初は不一致でも待つ間に一致へ転じれば成功すること
    /// (PollBackoff の初回間隔 100ms より長い waitSeconds を与え、遅れて一致するケースを再現)
    func testAppIsPollsUntilForegroundMatches() {
        let driver = RecordingDriver()
        driver.foregroundMatches = [false, false, true]
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { appIs("com.example.app", waitSeconds: 2) }
            }
        }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertGreaterThanOrEqual(driver.isAppForegroundQueried.count, 3,
                                    "1回で一致しないシナリオなので複数回ポーリングしているはず")
    }

    /// Android は失敗メッセージに actual の package 名を含めること
    func testAppIsTimesOutWithActualOnAndroid() {
        let driver = RecordingDriver()
        driver.foregroundAppIDValue = "com.other.app"
        let core = makeCore(driver: driver, platform: "android")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { appIs("com.example.app", waitSeconds: 0.3) }
            }
        }

        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertTrue(reason.contains("actual=\"com.other.app\""), reason)
    }

    // MARK: - flick

    /// centerTo系: 画面(400x800)全体を対象に中心→各端の座標が届くこと。screen は RecordingDriver.snapshot
    /// の固定値(400x800)。durationSeconds も既定(0.25)から変えていないので明示しない
    func testFlickCenterToTopComputesCenterToTopEdge() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { flickCenterToTop() }
            }
        }

        XCTAssertEqual(driver.dragCalls.count, 1)
        let call = driver.dragCalls[0]
        XCTAssertEqual(call.fromX, 200, accuracy: 0.001)
        XCTAssertEqual(call.fromY, 400, accuracy: 0.001)
        XCTAssertEqual(call.toX, 200, accuracy: 0.001)
        XCTAssertEqual(call.toY, 0, accuracy: 0.001)
        XCTAssertEqual(call.durationSeconds, FlowStep.defaultFlickDurationSeconds, accuracy: 0.001)
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// 端→端系: startMarginRatio が右端基準の式(Shirates 準拠)に反映されること
    func testFlickRightToLeftAppliesCustomStartMarginRatio() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { flickRightToLeft(startMarginRatio: 0.1) }
            }
        }

        XCTAssertEqual(driver.dragCalls.count, 1)
        let call = driver.dragCalls[0]
        // fromX = right * (1 - ratio) = 400 * 0.9、toX = 左端(0)
        XCTAssertEqual(call.fromX, 360, accuracy: 0.001)
        XCTAssertEqual(call.toX, 0, accuracy: 0.001)
        XCTAssertEqual(call.fromY, 400, accuracy: 0.001)
        XCTAssertEqual(call.toY, 400, accuracy: 0.001)
    }

    /// repeat=2: 同じ座標のドラッグが2回ドライバへ届くこと(Shirates は容器を測り直さない)
    func testFlickRepeatFiresDragTwice() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { flickCenterToBottom(repeat: 2, intervalSeconds: 0.01) }
            }
        }

        XCTAssertEqual(driver.dragCalls.count, 2)
        XCTAssertEqual(driver.dragCalls[0].toY, 800, accuracy: 0.001)
        XCTAssertEqual(driver.dragCalls[1].toY, 800, accuracy: 0.001)
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// durationSeconds が明示指定どおりドライバへ届くこと(tap の holdSeconds が 1.0 に潰れていた
    /// 実績があるため、flick でも同じ形で固定する)
    func testFlickCenterToRightDurationSecondsReachesDriver() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { flickCenterToRight(durationSeconds: 0.5) }
            }
        }

        XCTAssertEqual(driver.dragCalls.count, 1)
        XCTAssertEqual(driver.dragCalls[0].durationSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(driver.dragCalls[0].toX, 400, accuracy: 0.001)
    }

    // MARK: - tapAppIcon

    /// tapAppIcon 用: home/drag/tap(ref:) の呼び出しを記録し、snapshot() は呼び出し順で
    /// scriptedSnapshots を返す(尽きたら最後を繰り返す。RecordingDriver.foregroundMatches と同じ規約)
    private final class HomeScreenDriver: AppDriver {
        private(set) var homeCount = 0
        private(set) var dragCount = 0
        private(set) var tappedRefs: [Int] = []
        var scriptedSnapshots: [SnapshotResponse] = []
        private var snapshotCallCount = 0

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func home() async throws { homeCount += 1 }
        func snapshot() async throws -> SnapshotResponse {
            defer { snapshotCallCount += 1 }
            guard !scriptedSnapshots.isEmpty else {
                return SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [], truncatedCount: 0)
            }
            let index = min(snapshotCallCount, scriptedSnapshots.count - 1)
            return scriptedSnapshots[index]
        }
        func tap(ref: Int) async throws { tappedRefs.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                  pressSeconds: Double, durationSeconds: Double) async throws { dragCount += 1 }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func iconSnapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    private func iconElement(_ ref: Int, label: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "Icon", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 60, height: 60), depth: 0)
    }

    /// home 画面に最初から出ているアイコンは、ドロワー/ページ送りを一切せず即タップすること
    func testTapAppIconFindsIconOnCurrentScreen() {
        let driver = HomeScreenDriver()
        driver.scriptedSnapshots = [iconSnapshot([iconElement(3, label: "Maps")])]
        let core = makeCore(driver: driver, platform: "android")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon("Maps") } } }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(driver.homeCount, 1, "Android は home() 1回のみ(2回目は iOS だけの規律)")
        XCTAssertEqual(driver.dragCount, 0, "現在画面で見つかったならドロワーを開いてはいけない")
        XCTAssertEqual(driver.tappedRefs, [3])
    }

    /// iOS は Shirates 準拠で home() を2回撃つこと
    func testTapAppIconPressesHomeTwiceOnIOS() {
        let driver = HomeScreenDriver()
        driver.scriptedSnapshots = [iconSnapshot([iconElement(1, label: "Maps")])]
        let core = makeCore(driver: driver, platform: "ios")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon("Maps") } } }

        XCTAssertEqual(driver.homeCount, 2)
    }

    /// 現在画面に無いアイコンは、Android ならドロワーを開く flick(drag)を撃ってから再探索すること
    func testTapAppIconFindsIconAfterFlickOnAndroid() {
        let driver = HomeScreenDriver()
        driver.scriptedSnapshots = [
            iconSnapshot([iconElement(1, label: "Clock")]),               // home 画面: 対象なし
            iconSnapshot([iconElement(9, label: "Maps")]),                // ドロワーを開いた後
        ]
        let core = makeCore(driver: driver, platform: "android")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon("Maps") } } }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(driver.dragCount, 1)
        XCTAssertEqual(driver.tappedRefs, [9])
    }

    /// 画面が2回連続で変わらなければ打ち切り、Shirates 準拠の失敗文言で失敗すること
    func testTapAppIconFailsWithShiratesMessageWhenNeverFound() {
        let driver = HomeScreenDriver()
        // 全 snapshot が同一(ラベル集合不変)= 1回目の drag 後から「変化なし」が続く
        driver.scriptedSnapshots = [iconSnapshot([iconElement(1, label: "Clock")])]
        let core = makeCore(driver: driver, platform: "android")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon("Maps") } } }

        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertTrue(driver.tappedRefs.isEmpty)
        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertEqual(reason, "App icon not found.(Maps)")
        // 2回連続不変での早期打ち切り(上限8回まで引っ張らない)ことの確認
        XCTAssertEqual(driver.dragCount, 2)
    }

    /// 引数省略時は親が --app-name で渡したプロファイルの appName を既定に使うこと
    func testTapAppIconUsesProfileAppNameWhenArgumentOmitted() {
        let driver = HomeScreenDriver()
        driver.scriptedSnapshots = [iconSnapshot([iconElement(1, label: "FT E2E")])]
        let core = makeCore(driver: driver, platform: "android")
        core.appDisplayName = "FT E2E"
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon() } } }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(driver.tappedRefs, [1])
    }

    /// 引数省略で親からも表示名が来ていない(プロファイルに appName が無い)ときは明示エラー
    func testTapAppIconFailsWhenNameIsNilAndCannotBeResolved() {
        let driver = HomeScreenDriver()
        let core = makeCore(driver: driver, platform: "android")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon() } } }

        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(driver.homeCount, 0, "解決できないなら home() すら撃たないこと")
        guard case .failed(let reason) = core.finalRecord.scenes.flatMap(\.steps)[0].status else {
            return XCTFail("failed になっていない")
        }
        XCTAssertTrue(reason.contains("no appName to resolve it from"), reason)
    }

    /// hybrid では systemDriver(typeDriver=AppAttachDriver)ではなく fallbackDriver
    /// (SystemUIDriver 相当・springboard 参照)を使うこと。typeDriver は snapshot() のたび
    /// テスト対象アプリを再前面化してしまうため home 画面を見せられない(homeScreenDriver のコメント参照)
    func testTapAppIconUsesFallbackDriverNotTypeDriverOnHybrid() {
        let typeDriver = HomeScreenDriver()  // 呼ばれてはいけない
        let fallback = HomeScreenDriver()
        fallback.scriptedSnapshots = [iconSnapshot([iconElement(1, label: "Maps")])]
        let core = makeCore(driver: HomeScreenDriver(), typeDriver: typeDriver,
                            fallbackDriver: fallback, platform: "ios")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tapAppIcon("Maps") } } }

        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(fallback.tappedRefs, [1])
        XCTAssertEqual(typeDriver.homeCount, 0)
        XCTAssertEqual(typeDriver.tappedRefs, [])
    }
}
