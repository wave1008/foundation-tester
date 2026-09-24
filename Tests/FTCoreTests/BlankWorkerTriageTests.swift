// run の**開始前**に「画面だけ死んだ iOS シミュレータ」を弾く判定を固定する。
//
// 2026-08-05 に E2E-CMP の `-06` が「画面は真っ黒・a11y ツリーは健全・タップだけ届かない」
// 状態になり、**9/9 の失敗が無警告でテストの失敗として記録された**。Android には run 前の
// 同等処理(修復つき)が既にあり、iOS だけ無かった。
// **デバイスが要る部分(スクショの取得)は引数で受け、判定はここで固める**。

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FTTestSupport
@testable import FTCore

/// 撮るたびに違う絵を返せるようにするための箱(修復で画面が戻る形を作る)。
/// 参照型なのはテストが握ったまま中身を差し替えるため
private final class ShotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data
    init(_ data: Data) { storage = data }
    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// ログを取りこぼさずに集める(`log` は async 文脈から同期に呼ばれるので Task に逃がさない)
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// 撃たれた修復の記録
private actor Repaired {
    private(set) var labels: [String] = []
    func add(_ label: String) { labels.append(label) }
}

/// 判定に要らない口は呼ばれない前提のドライバ。**スクショだけは差し替えられる** ——
/// `excludeBlankScreenWorkers` 経由の経路はドライバから撮るので、既定の空 Data のままだと
/// 「デコード不能 = 健全」で素通りし、暗い実機の経路を1度も踏まないテストになる
private struct UnusedDriver: AppDriver {
    var shots: ShotBox = ShotBox(Data())
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { shots.data }
    func terminate() async throws {}
}

final class BlankWorkerTriageTests: XCTestCase {

    private func worker(_ label: String, platform: String = "ios",
                        physical: Bool = false, shot: Data = Data(),
                        box: ShotBox? = nil) -> RunWorker {
        RunWorker(label: label, platform: platform,
                  driver: UnusedDriver(shots: box ?? ShotBox(shot)),
                  connection: DriverConnection(platform: platform, physical: physical),
                  logicalName: label)
    }

    // MARK: - 対象の選び方

    /// 除外・回復まで行う本体の対象は **iOS の仮想デバイスだけ**。Android の仮想デバイスは
    /// 修復つきの自前トリアージが担当し、**実機は `observePhysicalScreens` が別に見る**
    /// (除外の門を通る側に実機を乗せない)
    func testOnlyVirtualIOSWorkersAreCandidates() {
        XCTAssertTrue(BlankWorkerTriage.isCandidate(worker("sim")))
        XCTAssertFalse(BlankWorkerTriage.isCandidate(worker("emu", platform: "android")),
                       "Android の仮想デバイスは自前のトリアージ(修復つき)が担当する")
        XCTAssertFalse(BlankWorkerTriage.isCandidate(worker("iphone", physical: true)),
                       "実機は observePhysicalScreens が見る(除外しない側)")
        XCTAssertFalse(BlankWorkerTriage.isCandidate(worker("pixel", platform: "android",
                                                           physical: true)))
    }

    // MARK: - 実機: 起きているのに一様

    /// **端末が起きていると申告しているのに一様 = 消灯ではない**。`darkScreenPhysical` と
    /// 別の根拠になり、ここだけが修復(sleep/wake)の対象になる
    func testAwakePhysicalDeviceGetsItsOwnEvidence() async {
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "serial-1", screenshot: { Self.blankPNG },
            physical: true, awake: { true }, environment: [:])
        XCTAssertEqual(verdict.evidence, [.awakeButBlankPhysical])
        XCTAssertFalse(verdict.isFrozen, "材料は揃っていてもまだ確定させない(警告から入れる規律)")
    }

    /// **読めなかった(nil)は消灯側へ倒す**。true に丸めると消灯した端末に修復を撃つ
    func testUnknownWakefulnessFallsBackToDarkScreen() async {
        for probe in [{ nil as Bool? }, { false as Bool? }] {
            let verdict = await BlankWorkerTriage.observedVerdict(
                key: "serial-1", screenshot: { Self.blankPNG },
                physical: true, awake: probe, environment: [:])
            XCTAssertEqual(verdict.evidence, [.darkScreenPhysical])
        }
    }

    /// **修復は「起きているのに一様」の台にだけ撃つ**。消灯かもしれない台には撃たない
    func testRepairFiresOnlyForTheAwakeButBlankDevice() async {
        let awakeWorker = worker("pixel-awake", platform: "android",
                                 physical: true, shot: Self.blankPNG)
        let darkWorker = worker("pixel-dark", platform: "android",
                                physical: true, shot: Self.blankPNG)
        let repaired = Repaired()
        await BlankWorkerTriage.observePhysicalScreens(
            [awakeWorker, darkWorker],
            awake: { $0.label == "pixel-awake" ? true : nil },
            repair: { await repaired.add($0.label) },
            environment: [:], log: { _ in })
        let labels = await repaired.labels
        XCTAssertEqual(labels, ["pixel-awake"], "消灯かもしれない台には撃たない")
    }

    /// **修復で戻ったら警告を出さない**。判定し直しは修復側の戻り値ではなく、
    /// こちらの観測器でやる(あちらの再判定はエミュレータ較正の閾値)
    func testRepairThatBringsTheScreenBackIsNotWarned() async {
        let box = ShotBox(Self.blankPNG)
        let device = worker("pixel", platform: "android", physical: true, box: box)
        let log = Collector()
        await BlankWorkerTriage.observePhysicalScreens(
            [device], awake: { _ in true },
            repair: { _ in box.data = Self.contentPNG },
            environment: [:], log: { log.add($0) })
        XCTAssertTrue(log.lines.contains { $0.contains("came back") }, "戻ったことを言う")
        XCTAssertFalse(log.lines.contains { $0.contains("still renders nothing") },
                       "戻ったのに警告を残さない")
    }

    /// 修復しても戻らなければ**警告のまま続行**(レーンからは外さない = 返り値が無いので
    /// 構造的に外せない)。文言は「手で見ろ・ツールは実機を再起動しない」まで言う
    func testDeviceThatDoesNotComeBackIsWarnedAndKept() async {
        let device = worker("pixel", platform: "android", physical: true,
                            box: ShotBox(Self.blankPNG))
        let log = Collector()
        await BlankWorkerTriage.observePhysicalScreens(
            [device], awake: { _ in true }, repair: { _ in },
            environment: [:], log: { log.add($0) })
        XCTAssertTrue(log.lines.contains { $0.contains("still renders nothing") })
        XCTAssertTrue(log.lines.contains { $0.contains("does not reboot a physical device") })
    }

    /// **実機の一様フレームは確定させない**。消灯が同じ絵を出すので、確定させると
    /// 夜間に寝ているだけの端末を凍結として除外・回復しようとする(除外の元の理由)
    func testPhysicalDarkScreenIsWarnedButNeverConfirmed() async {
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "00008130-DEAD",
            screenshot: { Self.blankPNG },
            physical: true,
            environment: [:])
        XCTAssertEqual(verdict.evidence, [.darkScreenPhysical])
        XCTAssertTrue(verdict.isSuspected, "警告としては出る")
        XCTAssertFalse(verdict.isFrozen, "確定させない = 除外も回復も撃たれない")

        // 同じ観測でも仮想デバイスなら確定する(対照)
        let virtual = await BlankWorkerTriage.observedVerdict(
            key: "SIM-UDID", screenshot: { Self.blankPNG }, environment: [:])
        XCTAssertTrue(virtual.isFrozen)
    }

    /// **実機には nudge を撃たない**(渡されても呼ばない)。画面を変える入力は端末の状態を
    /// 変えてしまうので、実機に「無害な入力」は無い
    func testPhysicalDeviceIsNeverNudged() async {
        var nudged = false
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "serial-1",
            screenshot: { Self.blankPNG },
            nudge: { nudged = true; return Self.contentPNG },
            physical: true,
            environment: [:])
        XCTAssertFalse(nudged, "実機では能動プローブを撃たない")
        XCTAssertEqual(verdict.evidence, [.darkScreenPhysical])
    }

    /// 暗い実機が混じっても**レーンから外れない**(警告までのスコープ)。
    /// 対照として同じ絵の仮想デバイスは外れることまで見る —— 片方だけだと
    /// 「そもそも blank と判定していない」テストと区別が付かない
    func testDarkPhysicalDeviceIsNotExcluded() async {
        let virtual = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker("sim", shot: Self.blankPNG)], environment: [:], log: { _ in })
        XCTAssertEqual(virtual.excluded, ["sim"], "同じ絵でも仮想デバイスは確定して外れる")

        let workers = [worker("iphone", physical: true, shot: Self.blankPNG)]
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            workers, environment: [:], log: { _ in })
        XCTAssertEqual(result.excluded, [], "実機は外さない")
        XCTAssertEqual(result.workers.map(\.label), ["iphone"])
    }

    // MARK: - 恒常 blank の判定

    /// **単発のフレームでは決めない**(起動直後の白/黒フレームを凍結と誤断する)
    func testOneBlankFrameIsNotEnough() async {
        var frames = [Self.blankPNG, Self.contentPNG]
        let blank = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { frames.isEmpty ? nil : frames.removeFirst() }, sleep: { _ in })
        XCTAssertFalse(blank, "2枚目が非一様なら健全")
    }

    /// **サンプル数は定数から採る**(窓を延ばしたときにテストが嘘にならないように)
    func testConsecutiveBlankFramesAreBlank() async {
        var frames = Array(repeating: Self.blankPNG, count: BlankWorkerTriage.samples)
        let blank = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { frames.isEmpty ? nil : frames.removeFirst() }, sleep: { _ in })
        XCTAssertTrue(blank)
    }

    /// **撮れなかったら健全に倒す**(誤って健全機を弾かない安全側)
    func testUnreadableScreenshotIsTreatedAsHealthy() async {
        let blank = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { nil }, sleep: { _ in })
        XCTAssertFalse(blank)
    }

    /// 健全機は**1サンプルで返る**(正常時の固定費はスクショ1枚)
    func testHealthyDeviceCostsOneSample() async {
        var taken = 0
        _ = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { taken += 1; return Self.contentPNG }, sleep: { _ in })
        XCTAssertEqual(taken, 1, "健全機で2枚撮ると run 開始が遅くなる")
    }

    // MARK: - 除外

    func testBlankWorkersAreExcludedKeepingOrder() {
        let workers = [worker("a"), worker("b"), worker("c")]
        let result = BlankWorkerTriage.exclude(workers, blankByLabel: ["b": true])
        XCTAssertEqual(result.workers.map(\.label), ["a", "c"], "順序を保つこと")
        XCTAssertEqual(result.excluded, ["b"])
    }

    func testNothingIsExcludedWhenAllHealthy() {
        let workers = [worker("a"), worker("b")]
        let result = BlankWorkerTriage.exclude(workers, blankByLabel: ["a": false])
        XCTAssertEqual(result.workers.count, 2)
        XCTAssertTrue(result.excluded.isEmpty)
    }

    /// 全滅しても空配列を返すだけ(呼び出し側が「ワーカー不在」として扱う)。
    /// ここで throw すると混在プロファイルの Android 側まで巻き添えになる
    func testAllBlankYieldsEmptyWithoutThrowing() {
        let workers = [worker("a"), worker("b")]
        let result = BlankWorkerTriage.exclude(workers, blankByLabel: ["a": true, "b": true])
        XCTAssertTrue(result.workers.isEmpty)
        XCTAssertEqual(result.excluded.sorted(), ["a", "b"])
    }

    // MARK: - フィクスチャ(PNG)

    /// 一様な黒 = 凍結時に実際に返ってくるフレーム(2026-08-05 実採取。**サイズは 42KB あった**ので
    /// ファイルサイズでは検出できず、画素をサンプルする BlankFrameDetector だけが効く)
    static let blankPNG = makePNG { context in
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    /// 内容のある画面(サンプル点が割れる)
    static let contentPNG = makePNG { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for row in 0..<8 where row.isMultiple(of: 2) {
            for col in 0..<8 where col.isMultiple(of: 2) {
                context.fill(CGRect(x: col * 8, y: row * 8, width: 8, height: 8))
            }
        }
    }

    private static func makePNG(_ draw: (CGContext) -> Void) -> Data {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        draw(context)
        guard let image = context.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }

    // MARK: - 能動プローブ
    //
    // 受動観測では**原理的に区別できない**2つの状態がある:
    //   「描画要求が無いだけの黒画面」= 入力すると描画が戻る(実測: HOME で 15KB → 1.4MB)
    //   「本物の wedge」= 入力しても戻らない
    // 一斉に force-stop/launch した直後に黒かった5台のうち、本物は1台だけだった。
    // 拍動(displayIdleSeconds)では分けられない(本物でも回り続ける)。この判別だけが全問正解した。

    /// **本丸**: 一様が続いても、入力で描画が戻るなら凍結ではない
    func testNudgeThatRestoresPaintingMeansHealthy() async {
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "udid-a", screenshot: { Self.blankPNG },
            nudge: { Self.contentPNG }, environment: [:])
        XCTAssertFalse(verdict.isFrozen, "入力で描画が戻る機を再起動してはいけない")
    }

    /// 入力しても一様のままなら**本物の wedge**
    func testNudgeThatChangesNothingMeansFrozen() async {
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "udid-a", screenshot: { Self.blankPNG },
            nudge: { Self.blankPNG }, environment: [:])
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertEqual(verdict.evidence, [.uniformBlank])
    }

    /// プローブが撮れなかった(nil)ときは保護側に倒す
    func testNudgeFailureFallsBackToFrozen() async {
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "udid-a", screenshot: { Self.blankPNG }, nudge: { nil }, environment: [:])
        XCTAssertTrue(verdict.isFrozen)
    }

    /// **健全機にはプローブを撃たない**(正常時に全機の前面を変えない)
    func testHealthyDeviceIsNeverNudged() async {
        var nudged = false
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "udid-a", screenshot: { Self.contentPNG },
            nudge: { nudged = true; return Self.contentPNG }, environment: [:])
        XCTAssertFalse(verdict.isFrozen)
        XCTAssertFalse(nudged, "一様でない機に撃つと毎 run 全機の前面が変わる")
    }

    /// プローブを渡さない呼び出しは従来どおり
    func testWithoutNudgeUniformIsStillFrozen() async {
        let verdict = await BlankWorkerTriage.observedVerdict(
            key: "udid-a", screenshot: { Self.blankPNG }, environment: [:])
        XCTAssertTrue(verdict.isFrozen)
    }
}

/// **レーンに凍結機を残さない**(ユーザー決定)。
/// 検出したら回復を試み、戻ったものはレーンに残し、**どうしても戻らないものだけ外す**。
///
/// 回復の実体(simctl shutdown→boot とブリッジの張り直し)は呼び出し側が注入する
/// (ProfileRunner)。ここで固定するのは**ループの契約**:
/// 回復する → 判定し直す → 戻れば全レーンで開始 / 戻らなければ外す。
final class BlankWorkerRecoveryTests: XCTestCase {

    /// 呼ばれた回数だけ blank / content を切り替えられるドライバ
    private final class SwitchableDriver: AppDriver, @unchecked Sendable {
        var frozen: Bool
        init(frozen: Bool) { self.frozen = frozen }
        func screenshot() async throws -> Data {
            frozen ? BlankWorkerTriageTests.blankPNG : BlankWorkerTriageTests.contentPNG
        }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func terminate() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                   path: FTSwipePath?) async throws {}
    }

    private func worker(_ label: String, frozen: Bool) -> RunWorker {
        RunWorker(label: label, platform: "ios", driver: SwitchableDriver(frozen: frozen),
                  connection: DriverConnection(platform: "ios", port: 8123, serial: nil,
                                               udid: "UDID-\(label)"))
    }

    /// 回復できたら**全レーンで開始**(除外0)
    func testRecoveredDevicesStayInTheLanes() async {
        let frozen = [worker("a", frozen: true), worker("b", frozen: false)]
        let recoverCalls = LockedBox(0)
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            frozen,
            recover: { _, _ in
                recoverCalls.mutate { $0 += 1 }
                // 回復 = ブリッジを張り直した健全なワーカー一覧を返す
                return [self.worker("a", frozen: false), self.worker("b", frozen: false)]
            },
            log: { _ in })
        XCTAssertEqual(recoverCalls.value, 1)
        XCTAssertTrue(result.excluded.isEmpty, "回復したのに外している: \(result.excluded)")
        XCTAssertEqual(result.workers.count, 2)
        // F10: 回復した台の label が run.json の blankRepairs に乗る欄(repaired)へ出ること。
        // 最初から健全だった "b" は含めない
        XCTAssertEqual(result.repaired, ["a"], "回復した台が repaired に出ていない")
    }

    /// **戻らない個体だけ外す**(レーンに凍結機を残さない)。上限まで試すこと
    func testUnrecoverableDeviceIsExcludedAfterTheRetries() async {
        let recoverCalls = LockedBox(0)
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker("dead", frozen: true), worker("ok", frozen: false)],
            recover: { _, _ in
                recoverCalls.mutate { $0 += 1 }
                return [self.worker("dead", frozen: true), self.worker("ok", frozen: false)]
            },
            log: { _ in })
        // **定数と突き合わせない**: 定数ごと 1 に書き換える変異を素通しする(2026-08-09 に実際に素通しした)。
        // 「1回で諦めない」ことが守りたい性質なので、回数そのもので縛る
        XCTAssertGreaterThanOrEqual(recoverCalls.value, 2, "1回で諦めている")
        XCTAssertEqual(recoverCalls.value, BlankWorkerTriage.recoveryAttempts,
                       "上限まで試していない")
        XCTAssertEqual(result.excluded, ["dead"])
        XCTAssertEqual(result.workers.map(\.label), ["ok"], "健全機まで巻き込んで外している")
        // F10: 戻らなかった台を回復扱いにしない(excluded と repaired の両方に出てはいけない)
        XCTAssertTrue(result.repaired.isEmpty, "戻らなかった台を repaired に出している")
    }

    /// 回復手段が無い(nil)なら**即座に外す**(無駄な再試行をしない)
    func testNoRecoveryMeansImmediateExclusion() async {
        let recoverCalls = LockedBox(0)
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker("dead", frozen: true)],
            recover: { _, _ in recoverCalls.mutate { $0 += 1 }; return nil },
            log: { _ in })
        XCTAssertEqual(recoverCalls.value, 1)
        XCTAssertEqual(result.excluded, ["dead"])
    }

    /// 凍結が無ければ回復は呼ばない(正常時に simctl を撃たない)
    func testHealthyFleetNeverCallsRecovery() async {
        let recoverCalls = LockedBox(0)
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker("a", frozen: false)],
            recover: { _, _ in recoverCalls.mutate { $0 += 1 }; return nil },
            log: { _ in })
        XCTAssertEqual(recoverCalls.value, 0)
        XCTAssertTrue(result.excluded.isEmpty)
    }

    /// **回復には「今の」ワーカー一覧が渡る**(2026-08-11 の実害)。
    /// 回復するとブリッジを張り直すので label(ポート)が変わる。呼び出し側が最初の一覧を
    /// 捕まえたままだと、2回目の試行で新しい label を引けず udid が取れずに必ず失敗する
    /// (`frozen devices have no iOS simulator udid`)。
    func testRecoveryReceivesTheCurrentWorkers() async {
        let seen = LockedBox<[[String]]>([])
        let attempt = LockedBox(0)
        _ = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker("dead(ios:8100)", frozen: true)],
            recover: { _, current in
                seen.mutate { $0.append(current.map(\.label)) }
                var next = 0
                attempt.mutate { $0 += 1; next = $0 }
                // 1回目の回復でポートが変わる(= label が変わる)。2回目もまだ凍結のまま
                return [self.worker("dead(ios:82\(next)0)", frozen: true)]
            },
            log: { _ in })
        XCTAssertEqual(seen.value.first, ["dead(ios:8100)"], "1回目は元の一覧")
        XCTAssertEqual(seen.value.dropFirst().first, ["dead(ios:8210)"],
                       "2回目は**張り直し後**の一覧でなければ label を引けない")
    }

    /// F10: 回復で label(ポート)が変わっても、同じ udid の台は同じ1台として repaired に数える。
    /// label をそのまま差し引く実装だと、回復した機は「別の未知の機」として見失われ
    /// run.json の blankRepairs に一度も乗らない(実害: M1Ultra の -02 が blankRepairs: null のまま)
    func testRepairedTrackingSurvivesALabelChangeFromRecovery() async {
        func w(_ label: String, port: UInt16, frozen: Bool) -> RunWorker {
            RunWorker(label: label, platform: "ios", driver: SwitchableDriver(frozen: frozen),
                      connection: DriverConnection(platform: "ios", port: port, serial: nil,
                                                   udid: "UDID-fixed"))
        }
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [w("dead(ios:8100)", port: 8100, frozen: true)],
            recover: { _, _ in
                // 回復でポートが変わる(= label が変わる)が udid(実体)は同じ
                [w("dead(ios:8210)", port: 8210, frozen: false)]
            },
            log: { _ in })
        XCTAssertTrue(result.excluded.isEmpty)
        XCTAssertEqual(result.repaired, ["dead(ios:8210)"],
                       "回復後の label(実際に run で使う方)で報告すること")
    }

    /// 回復を渡さない呼び出しは**従来どおり弾くだけ**(既存の呼び出し元を壊さない)
    func testWithoutRecoveryItStillJustExcludes() async {
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker("dead", frozen: true)], log: { _ in })
        XCTAssertEqual(result.excluded, ["dead"])
    }
}

/// **配線を守る**(ソース走査)。トリアージ側のループを検査するテストは、
/// 呼び出し側が `recover:` を渡さなくなる変更を素通しする —— 2026-08-09 の変異テストで
/// 実際に素通しした。`ProfileRunner` / `ApiRunCommand` は実プロファイル・実デバイスを
/// 要求するため単体で組めない。
///
/// **iOS ワーカーの供給口は3つある**。片方だけに回復を入れると、その経路の run だけ
/// 凍結機がレーンに残る(2026-08-09 に実際に1箇所しか入れず、既存コメントの警告どおり穴が空いた)
final class BlankWorkerRecoveryWiringTests: XCTestCase {

    /// (ファイル, その中に `excludeBlankScreenWorkers` が現れる回数)
    private static let supplySites = [
        ("Sources/fleetest/ProfileRunner.swift", 1),
        ("Sources/fleetest/ApiRunCommand.swift", 2),
    ]

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// **すべての供給口が `recover:` を渡す**。件数で縛るのは、供給口が増えたときに
    /// 「新しい経路だけ回復なし」を落とすため(呼び出し数と recover 数が一致しなければ失敗)
    func testEveryIOSSupplySitePassesARecoveryHook() throws {
        for (path, expectedCalls) in Self.supplySites {
            let text = try source(path)
            let calls = occurrences("excludeBlankScreenWorkers(", in: text)
            XCTAssertEqual(calls, expectedCalls,
                           "\(path): iOS トリアージの呼び出し数が変わった。増えたなら回復も渡すこと")
            XCTAssertEqual(occurrences("recover: { @Sendable frozen", in: text), calls,
                           "\(path): recover: を渡していない呼び出しがある(その経路だけ凍結機が残る)")
        }
    }

    /// 回復の**実体を呼んでいる**こと。`rebootFrozenSimulators` のような識別子を
    /// 素の contains で見ると**関数の定義**にも当たり、呼び出しを消す変異を素通しする
    /// (2026-08-09 の変異テストで実際に素通しした)。`await` + `(` まで含めて呼び出し形で縛る
    func testEverySupplySiteCallsTheRecoveryImplementation() throws {
        for (path, _) in Self.supplySites {
            let text = try source(path)
            XCTAssertTrue(text.contains("await ProfileWorkerFactory.recoverFrozenIOSWorkers("),
                          "\(path): 回復の実体を呼んでいない(フックが何もしないまま除外へ落ちる)")
        }
    }

    /// 回復の実体そのものが持つべき2工程 —— **simctl の再起動**と**ブリッジの張り直し**。
    /// シミュレータを落とすとブリッジも死ぬので、張り直しを省くと回復した機が使えない
    func testRecoveryRebootsTheSimulatorAndRebuildsTheBridge() throws {
        let text = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        guard let body = text.range(of: "func recoverFrozenIOSWorkers")
            .map({ String(text[$0.lowerBound...]) }) else {
            return XCTFail("recoverFrozenIOSWorkers が無い")
        }
        for fragment in ["\"simctl\", \"shutdown\"", "\"simctl\", \"boot\"",
                         "\"bootstatus\"", "buildIOSWorkers("] {
            XCTAssertTrue(body.contains(fragment), "回復から \(fragment) が消えている")
        }
    }
}
