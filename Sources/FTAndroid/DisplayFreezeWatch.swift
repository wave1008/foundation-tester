// DisplayFreezeWatch.swift
// run のレーンがシナリオの境目で撮った絵を前回と比べ(判定は FTCore.DisplayFreezeDetector)、止まっていれば
// 確かめ(home を押して絵が変わるか)、変わらなければデバイスを回復する。配線は ProfileRunOrchestrator →
// RunOrchestrator.checkLaneDisplay。確定したレーンは RunOrchestrator が .frozen と同じ扱いにする
// (直前のシナリオの結果を捨てて振り直し・レーンを離脱・revive で張り直す)。
//
// - 実機は見ない(無害な nudge も再起動も無い)。撮れないときは判定しない(前回の基準は残す)
// - 撮る経路: Android = ブリッジ(古い絵を返すのはこちら)/ iOS Simulator = OS(simctl io screenshot)。iOS の in-app の撮影は
//   SUT の中なので、確認の home で SUT が背面に回ると撮れなくなる(確認が成立しない)。OS 側なら前後とも同じ経路で比べられる
// - 確認の入力(home)を撃てなかったら判定しない(撃てていないのに「変わらなかった」と読むと、時計の無い静止画面の健全な
//   デバイスを再起動する)。確認の後に凍結でなければ SUT を前面へ戻す(後続のシナリオへ背面の状態を渡さない)
// - 回復の順(Android Emulator): sleep/wake(約 4 秒。ホスト GPU の合成バッファの固着にはこれで足りる実測 =
//   AndroidHealthProbe.repairBlankDisplay)→ 絵がまだ同じならゲストの再起動(adb reboot・約 1 分)→ ブートを
//   確認できなければ Emulator の停止と起動。iOS Simulator = shutdown → boot(run 前トリアージの凍結回復と同じ)。
//   再起動した後は絵で確かめない(ブリッジが死んでいて撮れない)= 次の境目の撮影が新しい基準になる
// - 陽性対照: DisplayFreezeDetector.frozenFrameInjectionKey(撮影を固定の絵に差し替える。回復まで本当に撃つ)

import FTBridgeClient
import FTCore
import Foundation

public actor DisplayFreezeWatch {
    public typealias Capture = @Sendable (RunWorker) async -> Data?
    /// 画面を必ず変える無害な入力を撃つ。**撃てたら true**(撃てなかったら確認は成立しない)
    public typealias Nudge = @Sendable (RunWorker) async -> Bool
    /// 確認で背面に回した SUT を前面へ戻す(bundle ID / パッケージ名が分からなければ何もしない)
    public typealias Restore = @Sendable (RunWorker, String?) async -> Void
    /// 回復を順に撃ち、**撃った回復の種類**を返す(nil = 何も撃てなかった)。`stillFrozen` は「今撮ると凍結時と同じ絵か」
    /// (撮れなければ true = 直ったと言えない)。sleep/wake の後だけ呼ぶ(再起動の後はブリッジが居ない)
    public typealias Repair = @Sendable (RunWorker, _ stillFrozen: @Sendable () async -> Bool,
                                         _ log: @escaping @Sendable (String) -> Void) async -> WorkerRecoveryKind?

    /// 1 枚の撮影に払う上限(秒)。**根拠**: 境目の撮影は XCUITest で数百 ms・Emulator で数十 ms。これを超えるのは
    /// ブリッジが答えない形で、その切り分けは RunOrchestrator の事後プローブの仕事。尽きたら判定しない(notChecked)
    public static let captureBudgetSeconds: Double = 10
    /// home を押した後、絵が変わるのを待つ上限(秒)と刻み(秒)。**根拠**: ランチャーの描画は負荷の高い Emulator でも
    /// 1〜2 秒(実測)。変わった瞬間に抜けるので、健全機が払うのは描画までの時間だけ・凍結機だけが上限を払う
    public static let nudgeChangeWaitSeconds: Double = 3
    public static let nudgeChangePollSeconds: Double = 0.3

    private var last: [String: DisplayFreezeDetector.Sample] = [:]
    private let baseline: Baseline
    private let capture: Capture
    private let nudge: Nudge
    private let restore: Restore
    private let repair: Repair
    private let now: @Sendable () -> TimeInterval

    public init(capture: @escaping Capture, nudge: @escaping Nudge, restore: @escaping Restore,
                repair: @escaping Repair, baseline: Baseline = .inMemoryOnly,
                now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.baseline = baseline
        self.capture = capture
        self.nudge = nudge
        self.restore = restore
        self.repair = repair
        self.now = now
    }

    /// デバイスの鍵(iOS = udid / Android = serial。RunLease と同じ体系)。実機と鍵の無い接続は nil = 見ない
    static func key(of worker: RunWorker) -> String? {
        guard !worker.connection.physical else { return nil }
        return worker.connection.udid ?? worker.connection.serial
    }

    /// `appID`: 確認で背面に回した後に前面へ戻す SUT(凍結が確定した回は戻さない = 回復が起動し直す)
    public func check(_ worker: RunWorker, restoring appID: String?,
                      log: @escaping @Sendable (String) -> Void) async -> LaneDisplayCheckOutcome {
        guard let key = Self.key(of: worker) else { return .notChecked }
        guard let png = await capture(worker) else { return .notChecked }
        let sample = DisplayFreezeDetector.Sample(png: png, at: now())
        // **基準は run をまたいで引き継ぐ**(`Baseline`)。run ごとの控えだけだと、レーンあたり 1〜2 本の run が続く間は
        // 同じ run の中で 60 秒離れた境目を2回迎えず、凍結した Emulator を一度も疑えない(負荷テストで実測:
        // ブリッジが 7 分前の絵を返し続け、可視性検証が見えている要素を赤にした)
        let previous = last[key] ?? baseline.load(key)
        // **同じ絵なら最初に見た時刻を保つ**(境目ごとに上書きすると、60 秒より短いシナリオが続く間は間隔が
        // 毎回リセットされて永久に疑えない)。絵が変わったときだけ基準を進める
        if previous?.digest != sample.digest { remember(key, sample) } else if last[key] == nil { last[key] = previous }
        guard case .suspect(let span) = DisplayFreezeDetector.judge(previous: previous, current: sample) else {
            return .healthy
        }
        log("⚠️ \(worker.label): the screen has not changed for \(Int(span))s (the same frame came back at two"
            + " scenario boundaries) — pressing home to check whether the display is frozen")
        guard await nudge(worker) else {
            log("⚠️ \(worker.label): could not press home to check the display — not judging it this time")
            return .notChecked
        }
        switch await changedAfterNudge(worker, from: sample.digest) {
        case .changed(let after):
            remember(key, after)
            log("✅ \(worker.label): the screen changed after the home press — the display is not frozen")
            await restore(worker, appID)
            return .healthy
        case .unobservable:
            await restore(worker, appID)
            return .notChecked
        case .unchanged:
            break
        }
        let detail = "the same frame came back for \(Int(span))s and did not change after a home press"
        log("❌ \(worker.label): the display is frozen (\(detail)) — recovering the device")
        let capture = self.capture
        let digest = sample.digest
        let recovery = await repair(worker, {
            guard let png = await capture(worker) else { return true }
            return DisplayFreezeDetector.digest(png) == digest
        }, log)
        // 回復の後は基準を捨てる(張り直したブリッジの最初の絵と、凍結前の絵を比べない)
        remember(key, nil)
        return .frozen(detail: detail, recovery: recovery)
    }

    private func remember(_ key: String, _ sample: DisplayFreezeDetector.Sample?) {
        last[key] = sample
        baseline.save(key, sample)
    }

    /// 境目の絵の基準の置き場(run をまたぐ)。時刻は壁時計(`now` の既定)なので別のプロセスの控えと比べられる。
    /// 読めない・壊れた控えは nil(= 基準なし。疑いが1回遅れるだけで、誤って疑う側には倒れない)
    public struct Baseline: Sendable {
        public let load: @Sendable (String) -> DisplayFreezeDetector.Sample?
        public let save: @Sendable (String, DisplayFreezeDetector.Sample?) -> Void

        public init(load: @escaping @Sendable (String) -> DisplayFreezeDetector.Sample?,
                    save: @escaping @Sendable (String, DisplayFreezeDetector.Sample?) -> Void) {
            self.load = load
            self.save = save
        }

        /// 控えを持たない(テスト用。本番は `files(in:)`)
        public static let inMemoryOnly = Baseline(load: { _ in nil }, save: { _, _ in })

        private struct Record: Codable { let digest: String; let at: TimeInterval }

        /// `<dir>/<鍵>.json`。1台の Mac で run は同時に1本(dispatch.lock)なので、書き手は1人
        public static func files(in dir: URL) -> Baseline {
            @Sendable func url(_ key: String) -> URL {
                let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
                return dir.appendingPathComponent("\(safe).json")
            }
            return Baseline(
                load: { key in
                    guard let data = try? Data(contentsOf: url(key)),
                          let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
                    return DisplayFreezeDetector.Sample(digest: record.digest, at: record.at)
                },
                save: { key, sample in
                    guard let sample else { try? FileManager.default.removeItem(at: url(key)); return }
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    guard let data = try? JSONEncoder().encode(Record(digest: sample.digest, at: sample.at)) else { return }
                    try? data.write(to: url(key), options: .atomic)
                })
        }
    }

    private enum NudgeResult {
        case changed(DisplayFreezeDetector.Sample)
        case unchanged
        /// 撮れなくなった(ブリッジが答えない)= 凍結とも健全とも言えない
        case unobservable
    }

    /// home の後、絵が `digest` と変わるまで刻みで撮り直す(上限 nudgeChangeWaitSeconds)。変わった瞬間に抜ける
    private func changedAfterNudge(_ worker: RunWorker, from digest: String) async -> NudgeResult {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.nudgeChangeWaitSeconds)
        while true {
            guard let png = await capture(worker) else { return .unobservable }
            let after = DisplayFreezeDetector.Sample(png: png, at: now())
            if after.digest != digest { return .changed(after) }
            guard clock.now < deadline else { return .unchanged }
            try? await Task.sleep(for: .seconds(Self.nudgeChangePollSeconds))
        }
    }

    // MARK: - 本番の部品

    /// 本番の配線(ProfileRunOrchestrator から)。`locale` は Emulator を起動し直したときに当て直す(AndroidLaneRecovery と同じ)
    public static func production(repoRoot: URL, locale: String,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> DisplayFreezeWatch {
        let injected = DisplayFreezeDetector.injectedKeys(environment: environment)
        return DisplayFreezeWatch(
            capture: { worker in await productionCapture(worker, injected: injected) },
            nudge: { worker in await productionNudge(worker) },
            restore: { worker, appID in await productionRestore(worker, appID: appID) },
            repair: { worker, stillFrozen, log in
                await productionRepair(worker, stillFrozen: stillFrozen, repoRoot: repoRoot, locale: locale, log: log)
            },
            baseline: .files(in: repoRoot.appendingPathComponent(".fleetest/display-freeze")))
    }

    /// 注入されたデバイスに返す固定の絵(中身は見ない = 同一バイトであることだけが要る)
    static let injectedFrame = Data("fleetest-frozen-frame-injection".utf8)

    static func productionCapture(_ worker: RunWorker, injected: Set<String>) async -> Data? {
        if let key = key(of: worker), injected.contains(key) { return injectedFrame }
        if worker.platform == "ios", let udid = worker.connection.udid {
            let outcome = await TaskBudget.run(.seconds(captureBudgetSeconds)) { simulatorScreenshot(udid: udid) }
            if case .value(let data) = outcome { return data }
            return nil
        }
        let outcome = await TaskBudget.run(.seconds(captureBudgetSeconds)) { try? await worker.driver.screenshot() }
        if case .value(let data) = outcome { return data }
        return nil
    }

    /// OS 側の撮影(simctl io screenshot)。終了コードが 0 で中身があるときだけ返す
    static func simulatorScreenshot(udid: String) -> Data? {
        let path = TemporaryDirectory.url.appendingPathComponent("ft-display-freeze-\(udid)-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let result = SimulatorActiveDisplay.simctlScreenshot(udid: udid, path: path, timeout: captureBudgetSeconds),
              result.status == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { return nil }
        return data
    }

    /// 画面を必ず変える無害な入力。ブリッジの home が無い(in-app は 501)ときは OS の口へ落ちる
    /// (Android = adb の KEYCODE_HOME / iOS Simulator = 設定アプリを前面に = run 前トリアージの nudgeIOSScreen と同じ)。
    /// **撃てたかを終了コードで返す**(どれも撃てなければ false = 確認は成立しない)
    static func productionNudge(_ worker: RunWorker) async -> Bool {
        if (try? await worker.driver.home()) != nil { return true }
        if worker.platform == "android", let serial = worker.connection.serial,
           let adbPath = try? AndroidDriver.findADB() {
            return (try? Shell.run([adbPath, "-s", serial, "shell", "input", "keyevent", "KEYCODE_HOME"],
                                   timeout: AndroidHealthProbe.adbTimeoutSeconds))?.status == 0
        }
        if worker.platform == "ios", let udid = worker.connection.udid {
            return (try? Shell.run(["xcrun", "simctl", "launch", udid, "com.apple.Preferences"], timeout: 20))?.status == 0
        }
        return false
    }

    /// 確認で背面に回した SUT を前面へ戻す。iOS は `simctl launch`(動いているプロセスを前面にするだけ = in-app の注入を保つ。
    /// ドライバの activate は in-app では起動し直しになる)/ Android はドライバの activate(monkey の LAUNCHER intent = 既存の
    /// タスクを前面に)。戻せなくても失敗にしない(次のシナリオは自分で起動する。ログに 1 行)
    static func productionRestore(_ worker: RunWorker, appID: String?) async {
        guard let appID, !appID.isEmpty else { return }
        if worker.platform == "ios", let udid = worker.connection.udid {
            if (try? Shell.run(["xcrun", "simctl", "launch", udid, appID], timeout: 20))?.status == 0 { return }
        } else if (try? await worker.driver.activate(bundleID: appID)) != nil {
            return
        }
        ConsoleOut.err("[display-freeze] \(worker.label): could not bring \(appID) back to the front after the check")
    }

    static func productionRepair(_ worker: RunWorker, stillFrozen: @Sendable () async -> Bool, repoRoot: URL,
                                 locale: String, log: @escaping @Sendable (String) -> Void) async -> WorkerRecoveryKind? {
        if worker.platform == "android" {
            guard let serial = worker.connection.serial else { return nil }
            return await repairEmulator(serial: serial, label: worker.label, stillFrozen: stillFrozen, locale: locale, log: log)
        }
        guard let udid = worker.connection.udid else { return nil }
        log("🔁 \(worker.label): rebooting the simulator (shutdown → boot)")
        // 先にこの機のブリッジを止める(掴んだまま落とすと shutdown がランナーの teardown を待つ。recoverFrozenIOSWorkers と同じ)
        _ = BridgeLauncher.stopMatching(udid: udid, repoRoot: repoRoot)
        _ = try? Shell.run(["xcrun", "simctl", "shutdown", udid])
        try? SimulatorBoot.ensureBooted(udid: udid, log: log)
        log("✅ \(worker.label): simulator is back")
        return .deviceRestart
    }

    /// Emulator の回復: sleep/wake → ゲストの再起動 → 停止と起動。撃った段を返す
    static func repairEmulator(serial: String, label: String, stillFrozen: @Sendable () async -> Bool,
                               locale: String, log: @escaping @Sendable (String) -> Void) async -> WorkerRecoveryKind? {
        log("🔧 \(label): sleep/wake to re-compose the display")
        _ = await AndroidHealthProbe.repairBlankDisplay(serial: serial)
        if await !stillFrozen() {
            log("✅ \(label): the display is drawing again after sleep/wake")
            return .displaySleepWake
        }
        log("🔁 \(label): sleep/wake did not restore the display — restarting the guest (adb reboot;"
            + " waiting up to \(Int(ProfileWorkerFactory.blankRebootTimeoutSeconds))s for boot)")
        if await ProfileWorkerFactory.rebootGuest(serial: serial, timeout: ProfileWorkerFactory.blankRebootTimeoutSeconds) {
            log("✅ \(label): the guest restarted")
            return .deviceRestart
        }
        guard let avdID = EmulatorControl.avdName(serial: serial) else {
            log("⚠️ \(label): could not confirm the guest restart, and the AVD name is unknown — not restarting the emulator")
            return .deviceRestart
        }
        log("🔁 \(label): could not confirm the guest restart — stopping and starting the emulator (\(avdID))")
        _ = await ProfileWorkerFactory.stopAndStartEmulator(serial: serial, avd: avdID, label: label, locale: locale, log: log)
        return .deviceRestart
    }
}
