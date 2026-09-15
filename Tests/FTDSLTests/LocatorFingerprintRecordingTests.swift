import XCTest
@testable import FTDSL
import FTCore

/// `FTDriveCore.perform` の指紋の記録条件: **プライマリ/フォールバックで素直に解決できた回だけ
/// 記録する**。指紋で解決した回まで記録すると、誤った解決が指紋として
/// 固定化され、以後ずっと同じ誤りを再生産する。デバイスを使わず、DSL → FTDriveCore.perform →
/// LocatorFingerprintCache.flush() の永続化ファイルを直接読んで確かめる(鍵の正確な文字列は
/// 知らなくてよい —— ファイルの有無・件数・中身だけを見る)。
final class LocatorFingerprintRecordingTests: XCTestCase {

    /// `#btn1` だけが在る画面。プライマリで素直に解決できる
    private final class PlainScreenDriver: AppDriver {
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
                elements: [ElementInfo(ref: 1, type: "button", identifier: "btn1", label: "修復対象",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)],
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

    /// `#id_seed` だけが在る画面(指紋を録る側の run)
    private final class SeedScreenDriver: AppDriver {
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
                elements: [ElementInfo(ref: 1, type: "button", identifier: "id_seed", label: "修復対象",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)],
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

    /// `#id_seed` は消え、同じ type+label の `#id_drifted` だけが在る画面(2本目の run)。**指紋だけ**で
    /// 解決させる。placeholder は種の画面に無い値を持たせてある —— 指紋は placeholder を控えていない
    /// (nil = 照合しない)ので一致は変わらず、**この要素から指紋を採り直すと placeholder が入る** =
    /// 再記録したかどうかを控えの中身で見分けられる
    private final class DriftedScreenDriver: AppDriver {
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
                elements: [ElementInfo(ref: 1, type: "button", identifier: "id_drifted", label: "修復対象",
                                       value: nil, placeholder: "drifted", enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)],
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

    /// 両 run で**同じソース行**から呼ぶための共有ヘルパー。DSL コマンドは呼び出し側の
    /// `#file`/`#line` を鍵に含めるので(`LocatorFingerprintCache.key`)、
    /// 2つのテストメソッドへ書き分けると別の鍵になってしまい、run1 で録った指紋が
    /// run2 で引けなくなる
    private func runTapOnIDSeed() {
        scenario { scene(1, "s") { action { tap("#id_seed") } } }
    }

    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-fingerprint-test-\(name)-\(UUID().uuidString).json")
    }

    private func readEntries(_ url: URL) -> [String: LocatorFingerprint] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LocatorFingerprint].self, from: data)
        else { return [:] }
        return decoded
    }

    /// **本題**: プライマリで素直に解決できたステップは指紋が記録される
    func testPrimaryResolutionRecordsFingerprint() {
        let fingerprintURL = tempURL("primary")
        let core = FTDriveCore(
            driver: PlainScreenDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Fingerprint.S0010", scenarioTitle: "t",
            delegate: nil, healingEnabled: false, dryRun: false,
            fingerprintCacheURL: fingerprintURL,
            emit: { _ in })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tap("#btn1") } } }
        core.flushLocatorFingerprints()

        let entries = readEntries(fingerprintURL)
        XCTAssertEqual(entries.count, 1,
                       "プライマリで解決したステップは指紋がちょうど1件記録されるはず")
        XCTAssertEqual(entries.values.first?.type, "button")
        XCTAssertEqual(entries.values.first?.label, "修復対象")
    }

    /// **最重要の陰性テスト**: 指紋で解決したステップ(`.healed`)は指紋を**記録し直さない**。
    /// 記録すると、誤った一致がそのまま指紋として固定化され、以後ずっと同じ誤りを再生産する。
    /// 「healed でも記録する」変異が入っていたら、控えの placeholder が "drifted" に書き換わって落ちる
    func testFingerprintHealedStepDoesNotRerecordItsFingerprint() {
        let fingerprintURL = tempURL("fp-no-rerecord")

        // run1: `#id_seed` がプライマリで解決できる画面 → 指紋が録られ、flush でディスクへ出る
        do {
            let core = FTDriveCore(
                driver: SeedScreenDriver(), platform: "ios", app: "com.example.app",
                scenarioID: "Fingerprint.S0040", scenarioTitle: "t",
                delegate: nil, healingEnabled: false, dryRun: false,
                fingerprintCacheURL: fingerprintURL,
                emit: { _ in })
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            runTapOnIDSeed()
            core.flushLocatorFingerprints()
        }
        XCTAssertEqual(readEntries(fingerprintURL).count, 1, "前提が崩れている: run1 で指紋が録れていない")
        XCTAssertNil(readEntries(fingerprintURL).values.first?.placeholder)

        // run2: `#id_seed` は消え、同じ type+label の `#id_drifted` だけが在る
        var run2Events: [ScenarioEvent] = []
        let core2 = FTDriveCore(
            driver: DriftedScreenDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Fingerprint.S0040", scenarioTitle: "t",
            delegate: nil, healingEnabled: true, dryRun: false,
            fingerprintCacheURL: fingerprintURL,
            emit: { run2Events.append($0) })
        FTRuntime.bootstrap(core: core2, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        runTapOnIDSeed()
        core2.flushLocatorFingerprints()

        // 前提: 指紋照合が実際に発火して healed になっていること(でなければ何も検証していない)
        let suggestion = run2Events.first { $0.kind == "fixSuggestion" }
        XCTAssertNotNil(suggestion, "前提が崩れている: 指紋照合が発火していない")
        XCTAssertEqual(suggestion?.newSelector, "#id_drifted")

        // **本題**: 控えは run1 のまま(drifted 要素から採り直していない)
        let entries = readEntries(fingerprintURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.values.first?.placeholder,
                     "指紋で解決した要素から指紋を採り直してはいけない(誤りの固定化)")
    }

    /// **問題3の回帰ガード**: シナリオが途中の失敗で中断しても、**それより前に成功したステップの
    /// 指紋は失われない**。ScenarioRunnerMain.swift の `defer { core.flushLocatorFingerprints() }`
    /// が中断経路でも必ず呼ぶことを、FTDriveCore 側の記録がそれに応えられることで模す
    /// (defer 自体は CLI 実行ファイル側のグルーコードでデバイス無しに叩けないため、
    /// ここでは「中断後に flush すれば録れているはず」を確かめる)
    func testFingerprintsRecordedBeforeAFailureAreStillFlushable() {
        let fingerprintURL = tempURL("aborted")
        let core = FTDriveCore(
            driver: PlainScreenDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Fingerprint.S0050", scenarioTitle: "t",
            delegate: nil, healingEnabled: false, dryRun: false,
            fingerprintCacheURL: fingerprintURL,
            emit: { _ in })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    tap("#btn1")               // 成功 → 指紋が録られる
                    tap("#definitely_missing") // 失敗 → シナリオ全体が中断する
                }
            }
        }

        // 前提: 2本目が落ちてシナリオ全体が失敗していること
        XCTAssertFalse(core.finalRecord.passed, "前提が崩れている: 2本目のタップが失敗していない")

        core.flushLocatorFingerprints()

        let entries = readEntries(fingerprintURL)
        XCTAssertEqual(entries.count, 1,
                       "中断より前に成功したステップの指紋は、シナリオが失敗しても失われてはいけない")
        XCTAssertEqual(entries.values.first?.type, "button")
        XCTAssertEqual(entries.values.first?.label, "修復対象")
    }

    /// `#btn_p` と `#btn_q` が在る画面(失効の実配線テスト run1)
    private final class WiringTwoButtonDriver: AppDriver {
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
                elements: [
                    ElementInfo(ref: 1, type: "button", identifier: "btn_p", label: "P",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0),
                    ElementInfo(ref: 2, type: "button", identifier: "btn_q", label: "Q",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 60, width: 100, height: 40), depth: 0),
                ],
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

    /// `#btn_p` だけが在る画面(失効の実配線テスト run2。`#btn_q` の行が消えたと想定する)
    private final class WiringOneButtonDriver: AppDriver {
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
                elements: [ElementInfo(ref: 1, type: "button", identifier: "btn_p", label: "P",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)],
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

    /// `tap("#btn_p")`/`tap("#btn_q")` を固定のソース行に置く共有ヘルパー。両 run が同じ行を
    /// 呼ぶことで、file:line を含む鍵(`LocatorFingerprintCache.key`)が run を跨いで一致する
    /// (runTapOnIDSeed と同じ理由)
    private func tapWiringP() { tap("#btn_p") }
    private func tapWiringQ() { tap("#btn_q") }
    private func runTapBothWiringButtons() {
        scenario { scene(1, "s") { action { tapWiringP(); tapWiringQ() } } }
    }
    private func runTapWiringButtonPOnly() {
        scenario { scene(1, "s") { action { tapWiringP() } } }
    }

    /// **失効規則の実配線確認**: `FTDriveCore.flushLocatorFingerprints()` は
    /// `LocatorFingerprintCache` の失効規則(scenarioPassed の導出込み)を実際に通す。
    /// 刈り取り条件そのものの網羅は `LocatorFingerprintExpiryTests` が担い、ここでは
    /// DSL → FTDriveCore.perform(record) → flushLocatorFingerprints(flush) の一気通貫を1本確かめる
    func testPassedScenarioPrunesUntouchedKeyThroughFTDriveCore() {
        let fingerprintURL = tempURL("expiry-wiring")

        // run1: `#btn_p` と `#btn_q` の両方をタップして解決 → 指紋が2件記録される
        do {
            let core = FTDriveCore(
                driver: WiringTwoButtonDriver(), platform: "ios", app: "com.example.app",
                scenarioID: "Fingerprint.ExpiryWiring", scenarioTitle: "t",
                delegate: nil, healingEnabled: false, dryRun: false,
                fingerprintCacheURL: fingerprintURL,
                emit: { _ in })
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            runTapBothWiringButtons()
            core.flushLocatorFingerprints()
        }
        XCTAssertEqual(readEntries(fingerprintURL).count, 2, "前提が崩れている: run1 で2件記録できていない")

        // run2: `#btn_q` の行が消えたと想定し `#btn_p` だけタップする。シナリオは通るので、
        // 触れなかった `#btn_q` の古い鍵は flushLocatorFingerprints() が刈るはず
        let core2 = FTDriveCore(
            driver: WiringOneButtonDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Fingerprint.ExpiryWiring", scenarioTitle: "t",
            delegate: nil, healingEnabled: false, dryRun: false,
            fingerprintCacheURL: fingerprintURL,
            emit: { _ in })
        FTRuntime.bootstrap(core: core2, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        runTapWiringButtonPOnly()

        XCTAssertTrue(core2.finalRecord.passed, "前提が崩れている: run2 が失敗している")
        core2.flushLocatorFingerprints()

        let entries = readEntries(fingerprintURL)
        XCTAssertEqual(entries.count, 1, "実配線でも触れなかった鍵は刈られるはず")
        XCTAssertEqual(entries.values.first?.label, "P")
    }

    /// 固定の要素だけを返すドライバ(下の3周テスト用)
    private final class FixedElementsDriver: AppDriver {
        let elements: [ElementInfo]
        init(_ elements: [ElementInfo]) { self.elements = elements }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func button(_ ref: Int, id: String, label: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: Double(ref) * 60, width: 100, height: 40), depth: 0)
    }

    /// 3周とも同じソース行から呼ぶ(鍵に file:line が入るため。runTapOnIDSeed と同じ理由)
    private func tapSeedLine() { tap("#id_seed") }
    private func runPThenSeed() {
        scenario { scene(1, "s") { action { tapWiringP(); tapSeedLine() } } }
    }

    /// **一部のステップだけが指紋で直ったシナリオでも、その指紋は次の run へ残る**。
    /// 旧実装は「record された鍵 = 触れた鍵」だったので、指紋で直ったステップ(record しない)の鍵が
    /// 同じシナリオの別ステップ(プライマリで通って record する)と並ぶと、通った run の終わりに
    /// 刈られていた —— run2 は緑、run3 で指紋を失って赤に戻る。「lookup を触れたに数えない」変異は
    /// run3 の healed が失敗に変わって落ちる
    func testFingerprintHealedKeySurvivesAlongsidePrimaryStepsAcrossRuns() {
        let fingerprintURL = tempURL("partial-heal-3runs")
        let scenarioID = "Fingerprint.PartialHeal"
        func run(_ elements: [ElementInfo], _ label: String) -> [ScenarioEvent] {
            var events: [ScenarioEvent] = []
            let core = FTDriveCore(
                driver: FixedElementsDriver(elements), platform: "ios", app: "com.example.app",
                scenarioID: scenarioID, scenarioTitle: "t",
                delegate: nil, healingEnabled: true, dryRun: false,
                fingerprintCacheURL: fingerprintURL,
                emit: { events.append($0) })
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            runPThenSeed()
            XCTAssertTrue(core.finalRecord.passed, "\(label) が失敗している")
            core.flushLocatorFingerprints()
            return events
        }

        // run1: 両方プライマリで解決 → 指紋2件
        _ = run([button(1, id: "btn_p", label: "P"), button(2, id: "id_seed", label: "修復対象")], "run1")
        XCTAssertEqual(readEntries(fingerprintURL).count, 2, "前提が崩れている: run1 で2件記録できていない")

        // run2 / run3: `#id_seed` だけがドリフト。`#btn_p` はプライマリで通り続ける
        let drifted = [button(1, id: "btn_p", label: "P"), button(2, id: "id_drifted", label: "修復対象")]
        for label in ["run2", "run3"] {
            let events = run(drifted, label)
            XCTAssertEqual(events.first { $0.kind == "fixSuggestion" }?.newSelector, "#id_drifted",
                           "\(label): 指紋で直っていない(指紋の鍵が前の run の終わりに刈られた)")
            XCTAssertEqual(readEntries(fingerprintURL).count, 2,
                           "\(label): 指紋で直った行の鍵が刈られている")
        }
    }
}
