import XCTest
@testable import FTDSL
import FTCore

/// `FTDriveCore.perform` の指紋の記録条件: **プライマリ/フォールバックで素直に解決できた回だけ
/// 記録する**。指紋やヒール(キャッシュ・FM)で解決した回まで記録すると、誤った解決が指紋として
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

    /// `#new_id` だけが在る画面(シナリオは `#old_id` を指すので素では解決できず FM ヒールが動く)。
    /// HealSuggestionRecordingTests.RenamedScreenDriver と同じ形
    private final class RenamedScreenDriver: AppDriver {
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
                elements: [ElementInfo(ref: 1, type: "button", identifier: "new_id", label: "OK",
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

    /// 改名先を必ず提案する delegate(FM の代わり)。HealSuggestionRecordingTests.RenamingHealer と同じ
    private final class RenamingHealer: ReplayDelegate {
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? {
            snapshot.elements.first.map {
                .proposed(HealProposal(element: $0, confidence: "high", rationale: "id renamed"))
            }
        }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
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

    /// `#id_seed` は消え、同じ type+label の `#id_drifted` だけが在る画面(2本目の run)。
    /// FM もヒールキャッシュも使わせず、**指紋だけ**で解決させる
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

    /// 両 run で**同じソース行**から呼ぶための共有ヘルパー。DSL コマンドは呼び出し側の
    /// `#file`/`#line` を鍵に含めるので(`HealCache.key`/`LocatorFingerprintCache` と共有)、
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
            healCacheURL: tempURL("primary-heal"),
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

    /// **最重要の陰性テスト**: FM 自己修復(ヒール)で解決したステップは記録**しない**。
    /// 記録してしまうと、誤ったヒール結果がそのまま指紋として固定化され、以後ずっと
    /// 同じ誤りを再生産する。「常に記録する」変異が入っていたら、ここでファイルが作られて落ちる
    func testHealedResolutionDoesNotRecordFingerprint() {
        var events: [ScenarioEvent] = []
        let fingerprintURL = tempURL("healed")
        let core = FTDriveCore(
            driver: RenamedScreenDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Fingerprint.S0020", scenarioTitle: "t",
            delegate: RenamingHealer(), healingEnabled: true,
            falsePositiveCheckEnabled: false, dryRun: false,
            healCacheURL: tempURL("healed-heal"),
            fingerprintCacheURL: fingerprintURL,
            emit: { events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tap("#old_id") } } }
        // ヒールが実際に発火したことを確認してからでないと、この陰性テストは何も検証していない
        // ことになる(FTDSLTests/HealSuggestionRecordingTests.swift と同じ確認)
        XCTAssertNotNil(events.first { $0.kind == "fixSuggestion" },
                        "前提が崩れている: ヒールが発火していない")
        core.flushLocatorFingerprints()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fingerprintURL.path),
                       "ヒールで解決した回を記録すると誤った解決が固定化される —— 書き出しすら発生しないはず")
        XCTAssertTrue(readEntries(fingerprintURL).isEmpty)
    }

    /// **問題1の回帰ガード**: 指紋で解決したステップは `heal-cache.json` へ書かない。
    /// 指紋照合は決定的で毎回同じコストで再導出できるので、キャッシュしても速度以外は増えない一方、
    /// 一致が実は別要素だった誤りをキャッシュへ書くと次回以降 `healedByCache` の枝に落ちて
    /// `heal-fingerprint-match` の注記ごと消え、指紋由来だったことが分からなくなる。
    /// FM ヒールは confidence=="high" の門を通ってからキャッシュに入るが、指紋照合にはその門が無い ——
    /// 門の無いものを固定化しない(docs/design.md §10)。「常に heal-cache へ書く」変異が入っていたら、
    /// run2 の heal-cache.json にエントリが現れて落ちる
    func testFingerprintResolutionDoesNotWriteToHealCache() {
        let fingerprintURL = tempURL("fp-no-healcache")

        // run1: `#id_seed` がプライマリで解決できる画面 → 指紋が録られ、flush でディスクへ出る
        do {
            let core = FTDriveCore(
                driver: SeedScreenDriver(), platform: "ios", app: "com.example.app",
                scenarioID: "Fingerprint.S0040", scenarioTitle: "t",
                delegate: nil, healingEnabled: false, dryRun: false,
                healCacheURL: tempURL("fp-no-healcache-run1-heal"),
                fingerprintCacheURL: fingerprintURL,
                emit: { _ in })
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            runTapOnIDSeed()
            core.flushLocatorFingerprints()
        }
        XCTAssertEqual(readEntries(fingerprintURL).count, 1, "前提が崩れている: run1 で指紋が録れていない")

        // run2: `#id_seed` は消え、同じ type+label の `#id_drifted` だけが在る。
        // healCache は空の別ファイルにする(cache 層を経由させず指紋層だけを踏ませるため)
        let run2HealCacheURL = tempURL("fp-no-healcache-run2-heal")
        var run2Events: [ScenarioEvent] = []
        let core2 = FTDriveCore(
            driver: DriftedScreenDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Fingerprint.S0040", scenarioTitle: "t",
            delegate: nil, healingEnabled: false, dryRun: false,
            healCacheURL: run2HealCacheURL,
            fingerprintCacheURL: fingerprintURL,
            emit: { run2Events.append($0) })
        FTRuntime.bootstrap(core: core2, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        runTapOnIDSeed()

        // 前提: 指紋照合が実際に発火して healed になっていること(でなければ何も検証していない)
        let suggestion = run2Events.first { $0.kind == "fixSuggestion" }
        XCTAssertNotNil(suggestion, "前提が崩れている: 指紋照合が発火していない")
        XCTAssertEqual(suggestion?.newSelector, "#id_drifted")

        // **本題**: heal-cache.json は作られない(FM 由来の rationale「FM self-heal」も出ない)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run2HealCacheURL.path),
                       "指紋で解決した回はヒールキャッシュへ書いてはいけない")
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
            healCacheURL: tempURL("aborted-heal"),
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
    /// 呼ぶことで、file:line を含む鍵(`HealCache.key`)が run を跨いで一致する
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
                healCacheURL: tempURL("expiry-wiring-run1-heal"),
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
            healCacheURL: tempURL("expiry-wiring-run2-heal"),
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
}
