// 解決済み実行プロファイル(ResolvedProfile)→ RunWorker 群の構築。CLI(ProfileRunner)から使う。
// FTBridgeClient と FTAndroid の両方に依存するため、このモジュール(FTAndroid)に置く。

import Foundation
import FTBridgeClient
import FTCore

public enum ProfileWorkerFactory {

    public struct InstallError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public static func buildWorkers(resolved: ResolvedProfile, repoRoot: URL,
                                    log: @escaping (String) -> Void) async throws -> [RunWorker] {
        let workers = try await buildIOSWorkers(resolved: resolved, repoRoot: repoRoot, log: log)
            + (try buildAndroidWorkers(resolved: resolved, log: log))
        guard !workers.isEmpty else {
            throw InstallError(message: "no usable workers (every device dropped out)")
        }
        return workers
    }

    /// iOS ワーカーのみ構築(ブリッジ供給込み=数十秒かかりうる)。Android と分離して呼べるのは
    /// 「Android を iOS 供給の完了待ちにしない」ため(RunOrchestrator の lateWorkers 参照)。
    public static func buildIOSWorkers(resolved: ResolvedProfile, repoRoot: URL,
                                       log: @escaping (String) -> Void) async throws -> [RunWorker] {
        guard !resolved.iosDevices.isEmpty else { return [] }
        let provisioner = BridgeProvisioner(repoRoot: repoRoot)
        let iosApp = resolved.apps["ios"]
        let provisioned = try await provisioner.provision(
            devices: resolved.iosDevices.map { ($0.name, $0.spec) },
            bundleID: iosApp?.bundleID,
            preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil,
            log: log)
        // 供給後に同期する(シミュレータのブートは provision 側。未ブートでは simctl spawn が失敗する)
        for device in provisioned where !device.physical {
            IOSReduceMotion.apply(udid: device.udid,
                                  animationsEnabled: resolved.enableAnimations, warn: log)
            IOSSoftwareKeyboard.apply(udid: device.udid, warn: log)
        }
        return provisioned.map { makeIOSWorker(device: $0, iosApp: iosApp) }
    }

    /// run 開始時に各デバイスへ `home()` を1回撃つ(実行プロファイルの `homeOnStart`。既定 true)。
    ///
    /// **予防措置**(2026-08-11 の実測): 一斉に launch した直後の端末は「描画要求が無いだけ」で
    /// 画面が黒いまま止まることがある(黒かった5台のうち4台は HOME を押した瞬間に 15KB → 1.4MB へ
    /// 戻った)。この状態は本物の凍結と受動観測では見分けが付かないので、**先に1回入力を入れて
    /// 描画を動かしておく**。デバイスあたり1回なので実行時間への影響はほぼ無い。
    ///
    /// **in-app ブリッジを持つ台には撃たない**(実測 2026-09-09、3機18台)。`home` はアプリを背面へ
    /// 送るが、**in-app ブリッジはそのアプリの中に居る**ので背面に回った瞬間に無応答になる ——
    /// 供給が「壊れたブリッジ」と見て停止・張り直しに入り、3機で13台がワーカーから脱落した
    /// (シナリオの結果は緑のままだが手元の run が 50s → 136s)。engine=inapp/hybrid は黙って飛ばす。
    ///
    /// 撃てる台(xcuitest 単独の iOS・Android)は `systemUIClient` 経由で XCUITest ブリッジへ回す
    /// —— `RunWorker.driver` は in-app ブリッジ宛のことがあり、in-app に `/home` のルートは無い。
    ///
    /// **結果は正直に出す**: 最初の実装は `try?` で握り潰して台数だけログしており、
    /// **1台も撃てていないのに成功したように見えていた**。
    public static func pressHomeOnStart(_ workers: [RunWorker], enabled: Bool,
                                        log: @escaping @Sendable (String) -> Void) async {
        guard enabled, !workers.isEmpty else { return }
        let plan = homeOnStartPlan(workers)
        let skippedNote = plan.skipped.isEmpty ? ""
            : " — skipped \(plan.skipped.count) device(s) with an in-app bridge"
                + " (home would send the app to the background and the bridge lives inside it)"
        guard !plan.targets.isEmpty else {
            log("🏠 pressed home on 0 device(s) (homeOnStart)\(skippedNote)")
            return
        }
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for worker in plan.targets {
                let driver: AppDriver = systemUIClient(for: worker) ?? worker.driver
                group.addTask { (try? await driver.home()) != nil }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        let done = results.filter { $0 }.count
        if done == results.count {
            log("🏠 pressed home on \(done) device(s) (homeOnStart)\(skippedNote)")
        } else {
            log("🏠 pressed home on \(done)/\(results.count) device(s) (homeOnStart)\(skippedNote)"
                + " — the rest could not be reached")
        }
    }

    /// `pressHomeOnStart` の対象と除外。**デバイス不要の純粋関数**(規則はここだけ・テストが直接叩く)。
    /// 除外は「in-app ブリッジを持つ台」だけ —— 判定は engine で行い、xcuiPort の有無では**決めない**
    /// (hybrid は両方のブリッジを持つので、xcuiPort があっても撃つとアプリが背面に落ちる)。
    static func homeOnStartPlan(
        _ workers: [RunWorker]
    ) -> (targets: [RunWorker], skipped: [RunWorker]) {
        var targets: [RunWorker] = []
        var skipped: [RunWorker] = []
        for worker in workers {
            let engine = worker.connection.engine
            if engine == "inapp" || engine == "hybrid" {
                skipped.append(worker)
            } else {
                targets.append(worker)
            }
        }
        return (targets, skipped)
    }

    /// run 開始時のデバイス準備を**1箇所に束ねる**。iOS ワーカーの供給口は3つあり、
    /// 個別に足すと必ずどれかを落とすので、開始時にやることはここへ集める
    public static func prepareDevicesOnStart(_ workers: [RunWorker], homeOnStart: Bool,
                                             log: @escaping @Sendable (String) -> Void) async {
        await pressHomeOnStart(workers, enabled: homeOnStart, log: log)
        await warnOnResidualSystemAlerts(workers, log: log)
    }

    /// run 開始時点で画面に残っているアラートを**警告する**(閉じない。理由と背景は
    /// FTCore.ResidualSystemAlertTriage)。閉じたいならシナリオの `iosAlertHandler`。
    ///
    /// **SpringBoard を見られる接続でしか判定できない**ので、engine=inapp 単独の台は黙って飛ばす
    /// (in-app ブリッジは注入先アプリのプロセスしか見えない = 「アラートが無い」と誤って言える)。
    /// 固定費は iOS ワーカーあたり snapshot 1枚で、全台並行に撃つ。
    /// **失敗は握りつぶす** —— これは診断であって run を止める理由にはしない
    /// **アプリの外(SpringBoard)を触れる driver**。in-app ブリッジは注入先アプリしか見えず
    /// `/home` のルートも持たないので、hybrid でも必ず XCUITest ブリッジ側へ回す
    /// (`RunWorker.driver` は in-app ブリッジ宛なので、そのまま使うと 0/N になる。実害 2026-09-09:
    /// homeOnStart が hybrid の全台で不発だったのに「inapp 固定の台だけができない」と説明していた)。
    /// iOS 以外・XCUITest ブリッジを持たない台は nil(呼び手は黙って飛ばす)。
    /// 使い手は pressHomeOnStart と warnOnResidualSystemAlerts の2つ。
    static func systemUIClient(for worker: RunWorker) -> BridgeClient? {
        guard worker.platform == "ios" else { return nil }
        let host = worker.connection.host ?? BridgeEndpoint.loopbackHost
        // 実機/シミュレータの UDID はここで分かっているので渡し切る
        // (PhysicalUDIDPlumbingTests の規律。渡さないと実機が名前引きの simctl 経路へ落ちる)
        let physicalUDID = worker.connection.physical ? worker.connection.udid : nil
        let simulatorUDID = worker.connection.physical ? nil : worker.connection.udid
        if let xcuiPort = worker.connection.xcuiPort {
            return BridgeClient(port: xcuiPort, host: host,
                                physicalUDID: physicalUDID, simulatorUDID: simulatorUDID)
        }
        let engine = worker.connection.engine
        guard engine == nil || engine == "xcuitest", let port = worker.connection.port else {
            return nil
        }
        return BridgeClient(port: port, host: host,
                            physicalUDID: physicalUDID, simulatorUDID: simulatorUDID)
    }

    public static func warnOnResidualSystemAlerts(
        _ workers: [RunWorker], log: @escaping @Sendable (String) -> Void
    ) async {
        let targets: [(String, BridgeClient)] = workers.compactMap { worker in
            guard let client = systemUIClient(for: worker) else { return nil }
            return (worker.label, client)
        }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: String?.self) { group in
            for (label, client) in targets {
                group.addTask {
                    guard let snapshot = try? await client.snapshot(),
                          let described = ResidualSystemAlertTriage.describe(
                            elements: snapshot.elements) else { return nil }
                    return "⚠️ \(label): an alert is already on screen before the run starts —"
                        + " \(described). It is drawn by another process, so it survives"
                        + " terminate/uninstall and will swallow every step until it is dismissed"
                }
            }
            for await line in group { if let line { log(line) } }
        }
    }

    /// **画面を必ず変える無害な入力**を送り、その後のフレームを返す(iOS シミュレータ)。
    /// `BlankWorkerTriage` の能動プローブ用。
    ///
    /// なぜ要るか(2026-08-11 の実測): 一斉に force-stop / launch した直後の黒画面は、
    /// **描画要求が無いだけ**で死んでいないことが多い(黒かった5台のうち本物の wedge は1台。
    /// 残り4台は HOME を押した瞬間に 15KB → 1.4MB へ戻った)。受動観測ではこの2つを区別できない。
    ///
    /// 実装の要点3つ:
    /// - 入力は**別アプリを前面に出す**(simctl に「ホームへ戻る」操作が無いため)
    /// - 撮影は **simctl**。in-app ブリッジは背面化で suspend するのでブリッジ経由では撮れない
    /// - **撃ったら SUT を前面へ戻す**。戻さないとブリッジが suspend したままになり、
    ///   ワーカーが `cannot connect (no response to status)` で離脱する
    ///   (フル E2E で10件発生。うち9件は Flutter iOS = プローブが最も発火するプロファイル)。
    ///   シナリオ側の `launchApp()` が起動し直すまでの窓を、ここで閉じる
    public static func nudgeIOSScreen(worker: RunWorker, restoring bundleID: String?) async -> Data? {
        guard let udid = worker.connection.udid else { return nil }
        _ = try? Shell.run(["xcrun", "simctl", "launch", udid, "com.apple.Preferences"], timeout: 20)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let path = NSTemporaryDirectory() + "ft-nudge-\(udid).png"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            if let bundleID {
                _ = try? Shell.run(["xcrun", "simctl", "launch", udid, bundleID], timeout: 20)
            }
        }
        guard let result = try? Shell.run(["xcrun", "simctl", "io", udid, "screenshot", path],
                                          timeout: 25), result.status == 0 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// 実行プロファイルから iOS の SUT の bundle ID を採る(プローブ後に前面へ戻すため)
    public static func iosBundleID(apps: [String: ResolvedAppTarget]) -> String? {
        apps["ios"]?.bundleID
    }

    /// run 開始時に Android 端末のアニメーション設定をプロファイルの enableAnimations へ合わせる。
    /// **ブリッジのコールド起動時の適用(AndroidBridge)だけでは足りない** — ブリッジは run を
    /// またいで再利用されるため、前の run が残した状態がそのまま残る。
    /// 呼び出しは buildAndroidWorkers の1箇所(run 開始の全経路がそこを通る)。
    /// iOS 側は buildIOSWorkers 内で供給後に同期する。
    /// 実機はグローバル設定が永続的に書き換わるので、**現在値を読んで差分があるときだけ**書き、
    /// そのときに1行知らせる(エミュレータは使い捨てなので無条件・無言)。失敗は非致命。
    public static func syncAnimationSettings(
        resolved: ResolvedProfile, log: (String) -> Void = { _ in }) {
        guard let adb = try? AndroidDriver.findADB(), !resolved.androidDevices.isEmpty else { return }
        let enabled = resolved.enableAnimations
        for device in resolved.androidDevices {
            guard let serial = try? AndroidDeviceCatalog.resolveSerial(spec: device.spec) else { continue }
            func shell(_ args: [String]) -> Shell.Result? {
                try? Shell.run([adb, "-s", serial] + args, timeout: 15)
            }
            if device.spec.isPhysical {
                let stale = AnimationPolicy.androidScaleKeys.filter {
                    !AndroidAnimationSettings.matches(
                        rawValue: shell(["shell"] + AndroidAnimationSettings.getArguments(key: $0))?.output,
                        animationsEnabled: enabled)
                }
                guard !stale.isEmpty else { continue }
                log("ℹ️ \(serial): setting the device animations "
                    + (enabled ? "back to the OS default (persists after the run)"
                               : "off (persists after the run)"))
            }
            let failed = AndroidAnimationSettings.apply(animationsEnabled: enabled) {
                shell(["shell"] + $0)?.status == 0
            }
            if !failed.isEmpty {
                log("⚠️ \(serial): could not apply the animation settings "
                    + "(\(failed.joined(separator: ", ")))")
            }
        }
    }

    /// excludeOrRepairBlankScreenWorkers の結果。repaired/excluded はワーカー label
    /// (RunSummary → RunMetaRecord(run.json)に監査記録として残る)。
    /// repaired は sleep/wake 修復と guest reboot 修復の両方を含む(run.json のスキーマは
    /// 「run 前に凍結を修復した個体」の1枠のまま。手段の別はログにのみ残す)
    public struct BlankScreenTriage {
        public let workers: [RunWorker]
        public let repaired: [String]
        public let excluded: [String]
    }

    /// guest reboot 後にブート完了を待つ上限(秒)。実測 ~60s。超過分を待ち続けても run 開始が
    /// 延びるだけなので打ち切り、blank 再判定に倒す(まだ blank なら除外)
    static let blankRebootTimeoutSeconds: TimeInterval = 120
    /// sys.boot_completed=1 から SystemUI 描画までの整定待ち(ナノ秒)
    static let bootSettleNs: UInt64 = 5_000_000_000
    /// 1回目の flap 検知(誤検知回避の2連続サンプル)のサンプル数・間隔。**変えない**
    /// (05809254 の意図的な選択: 誤除外のコストはワーカー1台減るだけ、という前提)。
    /// guest reboot 前の再判定・ログの根拠文はこの2値から導く(値を1箇所にする)
    static let flapCheckSamples = 2
    static let flapCheckIntervalMs: UInt64 = 1_500
    /// 空白判定の再判定ループ(guest reboot 後)のポーリング間隔。新しい時間の定数を増やさず
    /// flapCheckIntervalMs をそのまま使い回す
    static var blankPollIntervalNs: UInt64 { flapCheckIntervalMs * 1_000_000 }

    /// android かつ serial 判明済みのワーカーを対象に恒常 blank-screen(画面凍結)を並列判定し、
    /// **blank ならまず sleep/wake 修復(~4s)、不発なら guest reboot を同期発行してブート完了まで
    /// 待ち、本 run に復帰させる**(ユーザー決定: 台数が半減するのを避け、除外+非同期
    /// reboot で次 run 復帰にはしない)。除外は「reboot でも blank の
    /// まま」の最後の手段だけに残す。健全機は1サンプルで即返る。blank の確定は2連続サンプル ~1.5s
    /// (単発フレーム誤検知の回避): run 前の判定に既定の「40s ずっと blank」の確実性は過剰で、凍結が
    /// 1台でもあると setup 全体が ~37s に膨らむ(-gpu host の凍結は頻発。実測)。
    /// sleep/wake の実測は AndroidHealthProbe.repairBlankDisplay、reboot が難治型に唯一効くことの
    /// 実測根拠は rebootGuest 参照。guest reboot は emulator プロセスを再起動しないので **serial は
    /// 変わらない**(ワーカーの driver をそのまま使い続けられる = 呼び出し側の再構築が不要)。
    /// 事後の凍結判定(isBlankObserved・実行中の flap 検知)は別物。非 android ワーカーはそのまま
    /// 通し、元 workers の順序を維持する。
    /// 全除外で空になっても throw しない(混在プロファイルの iOS 合流を殺さない。呼び出し側が判断)
    /// `stateDir` を渡すと判定を共有ストア(`DeviceFrozenStore`)へ公表する。**iOS 側と同じ口**で、
    /// これが無いと「run は凍結を知っているのにモニターの ❄️ に出ない」非対称が残る
    public static func excludeOrRepairBlankScreenWorkers(
        _ workers: [RunWorker], stateDir: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: (String) -> Void) async -> BlankScreenTriage {
        // 実機は対象外。blank 判定(blankScreenMaxPNGBytes=30KB)は 1080x2424 エミュレータ較正で
        // 解像度の違う実機では当てにならず、誤判定すると健全な実機に adb reboot を撃ってしまう。
        // そもそも blank-screen はエミュレータの GPU 合成バッファ固着という固有の病理
        let candidates = workers.enumerated().filter {
            $0.element.platform == "android" && $0.element.connection.serial != nil
                && !$0.element.connection.physical
        }
        guard !candidates.isEmpty else {
            return BlankScreenTriage(workers: workers, repaired: [], excluded: [])
        }

        // タスクは (index, repaired) を返す: nil=健全 / repaired=true は修復済み(除外しない)
        // **回復したら公表を消す**(2026-08-11 の実害)。以前は回復の分岐ごとに `clear` を書いており、
        // **guest restart の分岐だけ落ちていた**ため、戻った機が run の間ずっと ❄️ のままになった
        // (モニターは公表を無条件に取り込む)。
        // **label と serial を1つの記録にまとめてある**のが要点 —— 回復の分岐を足すときに
        // 「レーンに残す」だけ書いて「公表を消す」を忘れる、が**型の上で起きない**
        var repairedDevices: [(label: String, serial: String)] = []
        defer {
            if let stateDir {
                for device in repairedDevices {
                    DeviceFrozenStore.clear(stateDir: stateDir, key: device.serial)
                }
            }
        }
        let outcomes = await withTaskGroup(of: (index: Int, repaired: Bool)?.self,
                                           returning: [(index: Int, repaired: Bool)].self) { group in
            for (index, worker) in candidates {
                group.addTask {
                    guard let serial = worker.connection.serial else { return nil }
                    // 陽性対照の注入は**公表だけ**通す(実体は健全なので sleep/wake も撃たない)。
                    // iOS 側(BlankWorkerTriage.observedVerdict)と同じ規律
                    if FrozenInjection.isInjected(key: serial, environment: environment) {
                        if let stateDir {
                            DeviceFrozenStore.publish(stateDir: stateDir, key: serial,
                                                      verdict: FrozenVerdict([.injected]))
                        }
                        return nil
                    }
                    guard await AndroidHealthProbe.isPersistentlyBlank(
                        serial: serial, samples: flapCheckSamples, intervalMs: flapCheckIntervalMs) else {
                        if let stateDir { DeviceFrozenStore.clear(stateDir: stateDir, key: serial) }
                        return nil
                    }
                    // **修復の前に公表する**(sleep/wake → guest reboot は分単位になりうる。
                    // 終わってから配るとモニターはその間ずっと「異常なし」を出す)
                    if let stateDir {
                        DeviceFrozenStore.publish(stateDir: stateDir, key: serial,
                                                  verdict: FrozenVerdict([.uniformBlank]))
                    }
                    let repaired = await AndroidHealthProbe.repairBlankDisplay(serial: serial)
                    return (index, repaired)
                }
            }
            var result: [(index: Int, repaired: Bool)] = []
            for await outcome in group {
                if let outcome { result.append(outcome) }
            }
            return result
        }
        repairedDevices = outcomes.sorted(by: { $0.index < $1.index }).filter(\.repaired)
            .compactMap { outcome in
                let worker = workers[outcome.index]
                guard let serial = worker.connection.serial else { return nil }
                return (worker.label, serial)
            }
        for device in repairedDevices {
            log("🔧 \(device.label): recovered a frozen (blank) screen with sleep/wake")
        }
        let stubbornIndices = outcomes.filter { !$0.repaired }.map(\.index).sorted()
        guard !stubbornIndices.isEmpty else {
            return BlankScreenTriage(workers: workers, repaired: repairedDevices.map(\.label), excluded: [])
        }

        // sleep/wake 不発の難治型を guest reboot で本 run 内に復帰させる。1台ずつ直列に処理する
        // (複数台の同時ブート描画は凍結そのもののトリガ=別個体を巻き込みうる。実測 2026-07-25)。
        // 該当は通常 0〜1台のため直列でも run 開始の遅延は reboot 1回ぶんに収まる
        var excludedIndices: Set<Int> = []
        for index in stubbornIndices {
            let worker = workers[index]
            guard let serial = worker.connection.serial else {
                excludedIndices.insert(index)
                log("⚠️ \(worker.label): the screen is blank but the serial is unknown, so it cannot be "
                    + "restarted — excluding it from dispatch")
                continue
            }
            // **破壊的な guest reboot(1〜2分)を撃つ前にもう一度、既定の窓(5サンプル×8秒 ≈40秒)で
            // 確かめる**。直前の flap 検知(2サンプル×1.5秒 ≈3秒)は画面遷移中の一過性の白画面
            // (約25秒周期でフラッピングする)も拾ってしまい、そのまま破壊的な再起動へ進めると
            // 健全機を巻き込む(実測: E2E-Flutter/android のラウンド開始時に毎回同じ1台がここで
            // 誤って再起動されていた)
            guard await AndroidHealthProbe.isPersistentlyBlank(serial: serial) else {
                repairedDevices.append((worker.label, serial))
                log("✅ \(worker.label): the blank screen cleared on its own (it was transient)"
                    + " — using it in this run")
                continue
            }
            log("🔁 \(worker.label): sleep/wake did not clear the frozen screen"
                + " (\(Self.uniformBlankEvidenceText(samples: flapCheckSamples, intervalMs: flapCheckIntervalMs)))"
                + " — restarting the guest"
                + " (waiting up to \(Int(blankRebootTimeoutSeconds))s for boot; it will be used in this run)")
            let rebootIssuedAt = Date()
            // ブート完了が確認できない個体は blank 再判定に進めず除外する: 再起動中は screencap 取得
            // 自体が失敗し、probeBlank はそれを「非 blank」(誤除外しない安全側)に倒すため、
            // 判定に掛けるとブート途中の個体を「復帰した」と誤認して run に載せてしまう
            guard await rebootGuest(serial: serial, timeout: blankRebootTimeoutSeconds) else {
                excludedIndices.insert(index)
                log("⚠️ \(worker.label): could not confirm the guest finished booting — "
                    + "excluding it from dispatch")
                continue
            }
            // ランチャー描画までの実測は ~60s(sys.boot_completed=1 直後の整定待ち bootSettleNs だけでは
            // 足りない個体がある)。1回判定で打ち切ると描画前の黒画面を「まだ空白」と誤除外するため、
            // **reboot を発行した時刻からの blankRebootTimeoutSeconds の残り**いっぱい、非空白が
            // 観測できるまで1回ずつ probe する(新しい時間の定数は作らない —— ポーリング間隔は
            // 上の flap 検知と同じ値を再利用する)
            var cleared = false
            while Self.blankPollShouldContinue(
                elapsedSeconds: Date().timeIntervalSince(rebootIssuedAt),
                budgetSeconds: blankRebootTimeoutSeconds) {
                if await !AndroidHealthProbe.isPersistentlyBlank(serial: serial, samples: 1, intervalMs: 0) {
                    cleared = true
                    break
                }
                try? await Task.sleep(nanoseconds: blankPollIntervalNs)
            }
            if cleared {
                repairedDevices.append((worker.label, serial))
                log("✅ \(worker.label): the guest restart cleared the frozen screen (using it in this run)")
                continue
            }
            excludedIndices.insert(index)
            log("⚠️ \(worker.label): the screen is still blank after a guest restart — excluding it from dispatch")
        }
        guard !excludedIndices.isEmpty else {
            return BlankScreenTriage(workers: workers, repaired: repairedDevices.map(\.label), excluded: [])
        }
        return BlankScreenTriage(
            workers: workers.enumerated().filter { !excludedIndices.contains($0.offset) }.map(\.element),
            repaired: repairedDevices.map(\.label),
            excluded: excludedIndices.sorted().map { workers[$0].label })
    }

    /// flap 検知の根拠を1行にした文(純粋関数。単体テスト対象)。
    /// 例: "the screen was a single uniform color in 2 captures 1.5s apart"
    static func uniformBlankEvidenceText(samples: Int, intervalMs: UInt64) -> String {
        let seconds = Double(intervalMs) / 1000
        let formatted = seconds.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", seconds) : String(format: "%.1f", seconds)
        return "the screen was a single uniform color in \(samples) captures \(formatted)s apart"
    }

    /// guest reboot 後、非空白の画面が観測できるまで待ち続けてよいか(純粋関数。単体テスト対象)。
    /// 予算(reboot を発行した時刻からの経過 vs blankRebootTimeoutSeconds)を使い切ったら
    /// 待つのをやめる(従来どおり、まだ空白なら除外)
    static func blankPollShouldContinue(elapsedSeconds: Double, budgetSeconds: Double) -> Bool {
        elapsedSeconds < budgetSeconds
    }

    /// guest reboot(adb reboot・不可なら gRPC RESET=VM リセット)を発行し、ブート完了まで待つ。
    /// sleep/wake が効かない難治型の凍結に唯一効くのが guest reboot(実測。docs/performance-tuning.md §7)。
    /// emulator プロセスは生かしたままなので serial・adb forward は維持される(デバイス常駐ブリッジは
    /// 死ぬが AndroidDriver.ensureBridge が次の操作で貼り直す)。
    /// 戻り値 false = 発行不能 or ブート完了を確認できず(呼び出し側は blank 再判定で最終判断する)
    private static func rebootGuest(serial: String, timeout: TimeInterval) async -> Bool {
        let adbPath = try? AndroidDriver.findADB()
        let issuedViaAdb = adbPath.flatMap {
            try? Shell.run([$0, "-s", serial, "reboot"], timeout: 15)
        }?.status == 0
        if !issuedViaAdb, await !EmulatorControl.reset(serial: serial) {
            return false
        }
        guard let adbPath else { return false }
        // reboot 発行直後はまだ旧セッションが sys.boot_completed=1 を返すため、先に「1 でなくなる」
        // ことを確認する(省くと waitForAndroidBoot が即成功し、再判定が凍結したままの旧画面に当たる)。
        // 停止を観測できないまま 30s 過ぎたらそのままブート待ちへ進む(最終判断は blank 再判定)
        let downDeadline = Date().addingTimeInterval(30)
        while Date() < downDeadline {
            let booted = try? Shell.run(
                [adbPath, "-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 5)
            if booted?.output.trimmingCharacters(in: .whitespacesAndNewlines) != "1" { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        do {
            try await DeviceBooter.waitForAndroidBoot(serial: serial, timeout: timeout)
        } catch {
            return false
        }
        // sys.boot_completed=1 の直後は SystemUI が未描画で画面が一様になりうる。整定を待たずに
        // 再判定すると回復済みの個体を「まだ blank」と誤判定して除外してしまう
        try? await Task.sleep(nanoseconds: bootSettleNs)
        return true
    }

    /// Android 実機の run 前準備(点灯+ロック解除+消灯抑止)。エミュレータは対象外。
    /// buildAndroidWorkers の前に呼ぶこと(呼ばないと実機が消灯したまま run が始まり、
    /// launch の前面判定が通らず全シナリオが 500 で落ちる)
    public static func preparePhysicalAndroidDevices(
        resolved: ResolvedProfile, log: @escaping (String) -> Void) async {
        for device in resolved.androidDevices where device.spec.isPhysical {
            guard let serial = device.spec.serial else { continue }
            await AndroidPhysicalDevice.prepareForRun(serial: serial, log: log)
        }
    }

    /// **起動しただけでは run できない**: コールドブート直後の Android は起動ストームの間、
    /// ブリッジ(ftbridge instrumentation)を立てても数秒で殺す(実測 2026-08-01:
    /// 起動17s→21s で死亡)。sys.boot_completed / bootanim / PackageManager 応答 /
    /// ランチャーの mCurrentFocus はどれもこの窓より手前で真になり、信号に使えなかった。
    /// よって**「立てて、生き続けることを確認する」自己検証で待つ**。
    /// これが機能する前提が AndroidBridge の .active 無効化(死んだクライアントを
    /// 握り続けない)で、それ以前は何度再試行しても同じ死体に当たっていた。
    ///
    /// **起こす側は `AndroidLaneRecovery.bootMissingDevices`**(直列・再試行・locale 適用)。
    /// ここはその直後に、**実際に起こせた分だけ**を渡して呼ぶ
    /// (起こせなかったレーンの扱いは `FTCore.LaneGate` の責務なので待たない)。
    /// buildAndroidWorkers より前に呼ぶこと
    /// **待ちは台ごとに並列**(実測 2026-09-09: 直列だと冷起動が ≈28 秒/台の台数比例になり、
    /// 手元8台で run 開始まで 3分41秒 —— そのうち約半分がこの待ちだった)。
    /// **直列にする理由は起こす側にしか無い** —— `AndroidLaneRecovery.bootMissingDevices` が
    /// 1台ずつなのは「複数台の同時ブート描画が画面凍結の契機」だから。こちらは `/status` を
    /// 叩いて待つだけで描画を伴わないので、束ねても同じ危険は無い。
    /// `wait` は1台分の待ちの差し込み口(既定 nil = 本番経路。テストは並列性だけを見る)。
    public static func awaitDurableAndroidBridges(
        devices: [ResolvedDevice], log: @escaping @Sendable (String) -> Void,
        wait: (@Sendable (_ spec: DeviceSpec, _ name: String) async -> Void)? = nil
    ) async {
        let targets = devices.filter { !$0.spec.isPhysical }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for device in targets {
                group.addTask {
                    if let wait {
                        await wait(device.spec, device.name)
                    } else {
                        await waitForDurableBridge(spec: device.spec, name: device.name, log: log)
                    }
                }
            }
            await group.waitForAll()
        }
    }

    /// ブリッジが**定着する**まで待つ(上限 bridgeDurableTimeout)。status 応答 → dwell 待つ →
    /// もう一度 status が通れば定着と判定する。期限切れは黙って返す(後段のワーカー生成が
    /// 同じ経路で立て直し、そちらのエラーが正になる)
    private static let bridgeDwellNs: UInt64 = 8_000_000_000
    private static let bridgeDurableTimeout: TimeInterval = 300
    private static func waitForDurableBridge(
        spec: DeviceSpec, name: String, log: @escaping @Sendable (String) -> Void) async {
        let deadline = Date().addingTimeInterval(bridgeDurableTimeout)
        var announced = false
        while Date() < deadline {
            if let serial = try? AndroidDeviceCatalog.resolveSerial(spec: spec),
               let driver = try? AndroidDriver(serial: serial),
               (try? await driver.status()) != nil {
                try? await Task.sleep(nanoseconds: bridgeDwellNs)
                if (try? await driver.status()) != nil { return }
            }
            if !announced {
                log("→ \(name): waiting for the bridge to stay up (a freshly booted guest kills it during the boot storm)")
                announced = true
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Android ワーカーのみ構築(serial 照合+ドライバ生成のみ=数秒)。
    /// アニメーション設定の同期もここで行う(run 開始の全経路がこの関数を通るため。
    /// Wipe Data / GPU 復帰の後に呼ぶこと = serial が確定している)。
    ///
    /// **1台の解決失敗で全体を落とさない**(2026-08-16 の実害: 別プロファイル実行中にエミュレータ
    /// 2台がプロセスごと死に、`try ... map` が丸ごと throw して後続3プロファイル74本が開始前に
    /// 全滅した。健全な6台は使われなかった)。集約規則は `FTCore.FleetOutcome.resolve`
    /// (iOS ブリッジ供給 `BridgeProvisioner.provision` と共有)。**全滅のときだけ**最初のエラーを
    /// throw する(呼び出し側が run の失敗として扱えるよう現状維持)。
    ///
    /// `makeWorker` は1台分の解決(serial 照合+ドライバ生成)の差し込み口。既定は本番経路
    /// (`makeAndroidWorker`)そのもので、テストはここへ失敗するスタブを渡して規則だけを検証する。
    public static func buildAndroidWorkers(
        resolved: ResolvedProfile, log: (String) -> Void = { _ in },
        makeWorker: (ResolvedDevice) throws -> RunWorker = ProfileWorkerFactory.makeAndroidWorker
    ) throws -> [RunWorker] {
        syncAnimationSettings(resolved: resolved, log: log)
        let outcomes: [(name: String, result: Result<RunWorker, Error>)] = resolved.androidDevices.map {
            device in (name: device.name, result: Result { try makeWorker(device) })
        }
        let aggregated = try FleetOutcome.resolve(outcomes)
        for failure in aggregated.failures {
            log("❌ \(failure.name): \(failure.error.localizedDescription)")
        }
        if !aggregated.failures.isEmpty {
            log("⚠️ \(aggregated.failures.count) device(s) could not be resolved"
                + " — continuing with \(aggregated.devices.count) device(s)")
        }
        return aggregated.devices
    }

    /// buildAndroidWorkers の既定解決経路(1台分)。serial 照合(`AndroidDeviceCatalog.resolveSerial`)と
    /// ドライバ生成(`AndroidDriver.init`)の両方の失敗を同じ扱いにする(片方だけ許容しない)。
    public static func makeAndroidWorker(device: ResolvedDevice) throws -> RunWorker {
        let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
        let driver = try AndroidDriver(serial: serial)
        return RunWorker(
            label: RunWorker.makeLabel(deviceName: device.name, platform: "android", id: serial),
            platform: "android",
            driver: driver,
            connection: DriverConnection(platform: "android", serial: serial,
                                         deviceName: device.name,
                                         physical: device.spec.isPhysical),
            logicalName: device.name)
    }

    /// engine=inapp/hybrid のときサブプロセスは InAppDriver(+hybrid は SystemUIDriver フォールバック)を
    /// 使う。suspend された in-app アプリは /status が無応答になるため、注入先アプリの bundleID を
    /// 明示的に渡してサブプロセスの inapp/XCUITest ルーティングを確定させる(engine 有りのみ)。
    /// CLI(makeIOSWorker)と MCP(MCPServer.runScenario)のプロファイル経路で共有する。
    public static func iosConnection(device: ProvisionedIOSDevice,
                                     iosApp: ResolvedAppTarget?) -> DriverConnection {
        let engine = (device.engine == "inapp" || device.engine == "hybrid") ? device.engine : nil
        return DriverConnection(platform: "ios", port: device.port,
                                engine: engine, udid: device.udid,
                                xcuiPort: device.xcuiPort,
                                inappBundleID: engine != nil ? iosApp?.bundleID : nil,
                                deviceName: device.name,
                                physical: device.physical,
                                host: device.physical ? device.host : nil)
    }

    /// ホスト warmup 用 driver は in-app ブリッジへの BridgeClient でよい(in-app も HTTP 応答する)。
    /// 実機は宛先ホスト(LAN or iproxy)と UDID を持たせる(install が devicectl 経路に入る)
    private static func makeIOSWorker(device: ProvisionedIOSDevice, iosApp: ResolvedAppTarget?) -> RunWorker {
        RunWorker(
            label: RunWorker.makeLabel(deviceName: device.name, platform: "ios", id: "\(device.port)"),
            platform: "ios",
            // **シミュレータでも UDID を渡す**: install/uninstall/clearAppData の対象特定が
            // ブリッジの status() に落ちると、removeApp() でアプリごとブリッジを消した直後の
            // installApp() が接続拒否で失敗する(BridgeClient.knownTarget の宣言)
            driver: BridgeClient(port: device.port, host: device.host,
                                 physicalUDID: device.physical ? device.udid : nil,
                                 simulatorUDID: device.physical ? nil : device.udid),
            connection: iosConnection(device: device, iosApp: iosApp),
            logicalName: device.name)
    }

    /// logicalName の1台だけを再供給する。到達不能・供給失敗は nil(throw しない)。
    public static func buildWorker(forLogicalName name: String, resolved: ResolvedProfile,
                                   repoRoot: URL, log: @escaping (String) -> Void) async -> RunWorker? {
        if let device = resolved.iosDevices.first(where: { $0.name == name }) {
            let provisioner = BridgeProvisioner(repoRoot: repoRoot)
            let iosApp = resolved.apps["ios"]
            // provision に 60s の期限を切る: ウェッジしたブリッジは接続を受けたまま応答せず、
            // BridgeClient の既定 120s/リクエストに任せると復帰ポーリング1回が数分止まる
            // (呼び出し側 reviveWorker の Date 期限は await 中は効かない)。キャンセルで確実に抜ける。
            // **実機は 60s に収まらない**: ランナーの起動→LAN 宣言(最大 startupTimeoutSeconds)→
            // /status(同じく最大 startupTimeoutSeconds)を直列に払う(build-for-testing は共有済み)。
            // 60s で切ると復帰が構造的に成立せず、切られた供給は続行して孤児ランナーを残していた
            // (2026-09-04 iPhone 13: 18 本中 17 本が「no usable workers」)。数字は launcher の
            // 2 段の締切から導く(独立した定数を置かない)
            let budgetSeconds: TimeInterval = device.spec.isPhysical
                ? 2 * BridgeLauncher.startupTimeoutSeconds : 60
            let provisioned = await withTaskGroup(of: [ProvisionedIOSDevice]?.self) { group in
                group.addTask {
                    try? await provisioner.provision(
                        devices: [(device.name, device.spec)],
                        bundleID: iosApp?.bundleID,
                        preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil,
                        log: log)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(budgetSeconds * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let first = provisioned?.first else { return nil }
            return makeIOSWorker(device: first, iosApp: iosApp)
        }
        if let device = resolved.androidDevices.first(where: { $0.name == name }) {
            do {
                let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
                let driver = try AndroidDriver(serial: serial)
                // ゲスト OS 再起動中でも serial 解決・ドライバ構築は成功してしまうため、status の
                // 疎通を確認してから返す(無検証で返すと呼び出し側が「復帰成功→即 status 死亡」で
                // 復帰上限を空費し、REVIVE_TIMEOUT の再試行ループが機能しない)。ウェッジした
                // ブリッジは応答を返さないことがあるため 10s 期限で打ち切る(iOS 分岐の 60s と同型)
                let reachable = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { (try? await driver.status()) != nil }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                guard reachable else { return nil }
                return RunWorker(
                    label: RunWorker.makeLabel(deviceName: device.name, platform: "android", id: serial),
                platform: "android",
                    driver: driver,
                    connection: DriverConnection(platform: "android", serial: serial,
                                                 deviceName: device.name,
                                                 physical: device.spec.isPhysical),
                    logicalName: device.name)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// autoInstall の差分スキップ判定(iOS: バンドル深比較 / Android: APK md5)。
    /// 判定不能は false(=インストールする)の安全側。
    private static func installedIsCurrent(worker: RunWorker, app: ResolvedAppTarget,
                                           appPath: String) -> Bool {
        if worker.platform == "ios" {
            // 実機のアプリコンテナはホストから読めない(simctl get_app_container 相当が無い)ので
            // 深比較できない。false=毎回インストールの安全側にする(実機の autoInstall は遅くなる)
            guard !worker.connection.physical, let udid = worker.connection.udid else { return false }
            return InstalledAppCheck.simulatorAppIsCurrent(
                udid: udid, bundleID: app.bundleID, appPath: appPath)
        }
        guard let android = worker.driver as? AndroidDriver else { return false }
        return android.installedPackageIsCurrent(packageID: app.bundleID, apkPath: appPath)
    }

    /// インストール失敗ワーカーは離脱し残りが続行する(全滅時のみエラー)。
    /// 判定(installedIsCurrent)〜必要なら install まではワーカー単位で並列(1タスク内で判定→install を直列に実行)。
    /// 戻り値は workers 順を維持する。
    /// forceAndroidInstall: true のとき android は autoInstall=false でも appPath があれば
    /// インストール候補に含める(AndroidDataWiper の Wipe Data でアプリが消えているため)
    public static func installIfNeeded(apps: [String: ResolvedAppTarget],
                                       workers: [RunWorker],
                                       forceAndroidInstall: Bool = false,
                                       log: @escaping (String) -> Void) async throws -> [RunWorker] {
        // 呼び出し元の log はスレッド安全という契約が無い(CLI 側 print 等)ため、並列区間からは
        // このロック越しラッパーのみを使う。
        let lock = NSLock()
        let safeLog: (String) -> Void = { msg in
            lock.lock()
            defer { lock.unlock() }
            log(msg)
        }

        var candidates: [(index: Int, worker: RunWorker, app: ResolvedAppTarget, appPath: String)] = []
        var passthrough: [(index: Int, worker: RunWorker)] = []
        for (index, worker) in workers.enumerated() {
            // inapp/hybrid の iOS はプロビジョニング時にインストール済み。ここで入れ直すと
            // 起動中の in-app ブリッジ(アプリ内常駐)が simctl install で終了してしまうため必ずスキップ
            if worker.platform == "ios", let engine = worker.connection.engine,
               engine == "inapp" || engine == "hybrid" {
                passthrough.append((index, worker))
                continue
            }
            let forceThis = forceAndroidInstall && worker.platform == "android"
            if let app = apps[worker.platform],
               let appPath = app.packagePath(physical: worker.connection.physical),
               app.autoInstall || forceThis {
                // 存在確認だけは直列のまま行う: 確定的な順序で早期 throw するため
                // (差分判定・インストールは下の TaskGroup で並列化)
                guard FileManager.default.fileExists(atPath: appPath) else {
                    throw InstallError(message: "package file not found: \(appPath)")
                }
                candidates.append((index, worker, app, appPath))
            } else {
                if forceThis,
                   apps[worker.platform]?.packagePath(physical: worker.connection.physical) == nil {
                    safeLog("⚠️ \(worker.label): appPath is required to reinstall after Wipe Data"
                        + " (appPath is not set in apps/)")
                }
                passthrough.append((index, worker))
            }
        }
        guard !candidates.isEmpty else { return workers }

        // N は差分判定前の候補数(判定した結果スキップになるものも含む数)
        log("→ Checking and installing the app (\(candidates.count) device(s))...")

        let installed = await withTaskGroup(of: (Int, RunWorker?).self,
                                            returning: [(Int, RunWorker)].self) { group in
            for (index, worker, app, appPath) in candidates {
                group.addTask {
                    // 差分スキップ: インストール済み内容がパッケージファイルと同一なら入れ直さない
                    if installedIsCurrent(worker: worker, app: app, appPath: appPath) {
                        safeLog("→ \(worker.label): installed app is already up to date — skipping (autoInstall)")
                        return (index, worker)
                    }
                    do {
                        try await installOne(worker: worker, bundleID: app.bundleID, appPath: appPath)
                        safeLog("✅ \(worker.label): install complete")
                        return (index, worker)
                    } catch {
                        safeLog("❌ \(worker.label): dropped out after an install failure — "
                            + error.localizedDescription)
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, RunWorker)] = []
            for await (index, worker) in group {
                if let worker { results.append((index, worker)) }
            }
            return results
        }

        // TaskGroup は完了順で返るため、passthrough と合流して index で元の workers 順に戻す
        let result = (passthrough + installed.map { (index: $0.0, worker: $0.1) })
            .sorted { $0.index < $1.index }.map { $0.worker }
        guard !result.isEmpty else {
            throw InstallError(message: "every worker failed to install the app")
        }
        return result
    }

    /// 1 ワーカーへの実インストール。installIfNeeded の TaskGroup 本体と installApp() の RPC ハンドラ
    /// (InstallHandlerFactory)が共用する唯一の実行口(ロジックを複製しない)。差分スキップ
    /// (installedIsCurrent)は呼ばない — 呼び出し側の判断に委ねる(installApp() は明示要求なので
    /// 常に実行、installIfNeeded は自動インストールなのでスキップ判定を挟む)
    public static func installOne(worker: RunWorker, bundleID: String, appPath: String) async throws {
        try await worker.driver.install(packagePath: appPath)
        if worker.platform == "ios", let udid = worker.connection.udid {
            InstalledAppCheck.recordInstalled(udid: udid, bundleID: bundleID, appPath: appPath)
        }
    }

    /// 凍結したシミュレータを **shutdown → boot** で戻し、**ブリッジを張り直した**
    /// ワーカー一覧を返す(BlankWorkerTriage の `recover:` にそのまま渡せる形)。
    ///
    /// シミュレータを落とす前に**その機のブリッジを止める**(掴んだままだと shutdown が約50秒
    /// かかる。下の実測コメント)。張り直しは `buildIOSWorkers` を呼び直すだけでよい ——
    /// 生きているブリッジは再利用されるので、実際に建て直るのは落とした機だけ。
    ///
    /// **2台ずつ**戻す: 一斉 boot は凍結の相関要因そのもので、start-device の「同時2台」と同じ理屈。
    /// udid はワーカーの connection から採る(label は表示用で simctl には渡せない)。
    ///
    /// **iOS ワーカーの供給口は3つある**(ProfileRunner の遅延合流 / ApiRunCommand の遅延合流 /
    /// ApiRunCommand の直接供給)。**片方だけに入れない** —— 過去に同じ型の穴を空けている
    public static func recoverFrozenIOSWorkers(
        labels: [String], workers: [RunWorker], resolved: ResolvedProfile, repoRoot: URL,
        apps: [String: ResolvedAppTarget], log: @escaping @Sendable (String) -> Void
    ) async -> [RunWorker]? {
        let targets = frozenIOSTargets(labels: labels, workers: workers)
        guard !targets.isEmpty else {
            log("⚠️ frozen devices have no iOS simulator udid — cannot reboot them")
            return nil
        }
        for pair in stride(from: 0, to: targets.count, by: 2) {
            let slice = Array(targets[pair..<Swift.min(pair + 2, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for (label, udid) in slice {
                    group.addTask {
                        log("→ \(label): rebooting the simulator (shutdown → boot)")
                        // **先にこの機のブリッジを止める**。掴んだまま落とすと `simctl shutdown` が
                        // XCUITest ランナーの teardown を待って **約50秒**かかり(止めてからなら約5秒)、
                        // 生き残ったランナーが再ブート後に再接続してくるので張り直しも遅い
                        // (2026-08-11 実測・3周とも一致: 96.5s → 34.6s)。
                        // 止めるのは**この udid のブリッジだけ**(他機・他セッションは巻き込まない)
                        _ = BridgeLauncher.stopMatching(udid: udid, repoRoot: repoRoot)
                        _ = try? Shell.run(["xcrun", "simctl", "shutdown", udid])
                        _ = try? Shell.run(["xcrun", "simctl", "boot", udid])
                        // boot 完了まで待つ(待たずに注入すると launch が失敗する)
                        _ = try? Shell.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
                        log("✅ \(label): simulator is back")
                    }
                }
            }
        }
        guard var rebuilt = try? await buildIOSWorkers(resolved: resolved, repoRoot: repoRoot,
                                                       log: log) else { return nil }
        do {
            rebuilt = try await installIfNeeded(apps: apps, workers: rebuilt,
                                                forceAndroidInstall: false, log: log)
        } catch {
            // install 全滅なら回復そのものを不成立にする(F5)。ここで古いアプリのまま
            // rebuilt を使い続けると、シミュレータは戻ったのに中身は古いままレーンへ復帰する。
            // nil を返すと BlankWorkerTriage 側が「回復できなかった」として通常の除外へ進む
            log("❌ recovered iOS device(s) dropped out after an install failure — "
                + error.localizedDescription)
            return nil
        }
        return mergeRecoveredIOS(into: workers, rebuiltIOS: rebuilt)
    }

    /// 録画ありの run で、**端末側に録画セッションが残った iOS シミュレータ**を再起動して解く
    /// (HostRecordingProbe の宣言)。再起動は凍結の回復と同じ `recover`(既定は
    /// recoverFrozenIOSWorkers = ブリッジ停止 → shutdown → boot → 張り直し)。
    ///
    /// **台を外さない** —— 録画は付帯機能なので、解けなかった台もテストは走らせる(録画だけ
    /// IOSSimulatorVideoRecorder.start が警告して飛ばす)。**不明の台は再起動しない**
    /// (検査が言えなかったことを理由に台を落とさない)。録画しない run では何もしない
    /// (検査そのものが録画の開始・停止なので、要らない run に払わせない)。
    ///
    /// **iOS ワーカーの供給口3つ全部から呼ぶ**(recoverFrozenIOSWorkers と同じ。配線は
    /// HostRecordingProbeTests.testEverySupplyPathRecoversStaleRecordingAfterTheBlankTriage が固定)
    public static func recoverStaleRecordingIOSWorkers(
        workers: [RunWorker], resolved: ResolvedProfile, repoRoot: URL,
        apps: [String: ResolvedAppTarget],
        probe: (@Sendable (String) async -> HostRecordingProbe.Outcome)? = nil,
        recover: (@Sendable ([String], [RunWorker]) async -> [RunWorker]?)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async -> [RunWorker] {
        guard resolved.record else { return workers }
        let workDir = repoRoot.appendingPathComponent(".fleetest/recording-probe")
        let probeOne = probe ?? { await HostRecordingProbe.probe(udid: $0, workDir: workDir) }
        let recoverWith = recover ?? { labels, current in
            await recoverFrozenIOSWorkers(labels: labels, workers: current, resolved: resolved,
                                          repoRoot: repoRoot, apps: apps, log: log)
        }
        let busy = await busyRecordingLabels(workers, probe: probeOne)
        guard !busy.isEmpty else { return workers }
        log("⚠️ \(busy.count) simulator(s) hold a stale host recording session (\(busy.joined(separator: ", ")))"
            + " — rebooting them before the run starts so they can be recorded")
        guard let rebuilt = await recoverWith(busy, workers) else {
            log("⚠️ could not reboot the simulator(s) holding a stale recording session —"
                + " they still run the tests, but will not be recorded")
            return workers
        }
        let stillBusy = await busyRecordingLabels(rebuilt, probe: probeOne)
        if stillBusy.isEmpty {
            log("✅ the stale recording session(s) are gone — recording every simulator")
        } else {
            log("⚠️ \(stillBusy.joined(separator: ", ")): the recording session is still held after a reboot"
                + " — these run the tests, but will not be recorded")
        }
        return rebuilt
    }

    /// busy の台の label(並列に検査する。対象は録画できる iOS シミュレータだけ = 実機と Android は見ない)
    static func busyRecordingLabels(
        _ workers: [RunWorker], probe: @escaping @Sendable (String) async -> HostRecordingProbe.Outcome
    ) async -> [String] {
        let targets = workers.compactMap { worker -> (String, String)? in
            guard worker.platform == "ios", !worker.connection.physical,
                  let udid = worker.connection.udid else { return nil }
            return (worker.label, udid)
        }
        return await withTaskGroup(of: (String, HostRecordingProbe.Outcome).self) { group in
            for (label, udid) in targets {
                group.addTask { (label, await probe(udid)) }
            }
            var busy: [String] = []
            for await (label, outcome) in group where outcome == .busy { busy.append(label) }
            return busy.sorted()
        }
    }

    /// 再起動をかける対象。**iOS だけ**を採る —— 呼び出し元の一覧は Android と混ざっている
    /// ことがあり(ApiRunCommand の直接供給)、Android の凍結機はここへ来る前に別経路
    /// (`excludeOrRepairBlankScreenWorkers`)が修復済み。simctl は udid でしか撃てないので
    /// udid の無い個体も落とす
    static func frozenIOSTargets(labels: [String],
                                 workers: [RunWorker]) -> [(label: String, udid: String)] {
        workers.filter { labels.contains($0.label) && $0.platform == "ios" }
            .compactMap { worker in
                guard let udid = worker.connection.udid else { return nil }
                return (worker.label, udid)
            }
    }

    /// **非 iOS は元のまま残す** —— `buildIOSWorkers` は iOS しか作らないので、混在一覧を
    /// 返り値でそのまま置き換えると Android のレーンが消える
    static func mergeRecoveredIOS(into original: [RunWorker],
                                  rebuiltIOS: [RunWorker]) -> [RunWorker] {
        original.filter { $0.platform != "ios" } + rebuiltIOS
    }

}
