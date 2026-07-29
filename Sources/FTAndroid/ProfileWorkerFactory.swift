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
            + (try buildAndroidWorkers(resolved: resolved))
        guard !workers.isEmpty else {
            throw InstallError(message: "実行可能なワーカーがありません(全デバイスが離脱しました)")
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
        return provisioned.map { makeIOSWorker(device: $0, iosApp: iosApp) }
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

    /// android かつ serial 判明済みのワーカーを対象に恒常 blank-screen(画面凍結)を並列判定し、
    /// **blank ならまず sleep/wake 修復(~4s)、不発なら guest reboot を同期発行してブート完了まで
    /// 待ち、本 run に復帰させる**(ユーザー決定 2026-07-26。以前は除外+非同期 reboot で次 run 復帰
    /// だったが、台数が半減するのを避けて本 run 内で直す方針にした)。除外は「reboot でも blank の
    /// まま」の最後の手段だけに残す。健全機は1サンプルで即返る。blank の確定は2連続サンプル ~1.5s
    /// (単発フレーム誤検知の回避): run 前の判定に既定の「40s ずっと blank」の確実性は過剰で、凍結が
    /// 1台でもあると setup 全体が ~37s に膨らむ(-gpu host の凍結は頻発。実測)。
    /// sleep/wake の実測は AndroidHealthProbe.repairBlankDisplay、reboot が難治型に唯一効くことの
    /// 実測根拠は rebootGuest 参照。guest reboot は emulator プロセスを再起動しないので **serial は
    /// 変わらない**(ワーカーの driver をそのまま使い続けられる = 呼び出し側の再構築が不要)。
    /// 事後の凍結判定(isBlankObserved・実行中の flap 検知)は別物。非 android ワーカーはそのまま
    /// 通し、元 workers の順序を維持する。
    /// 全除外で空になっても throw しない(混在プロファイルの iOS 合流を殺さない。呼び出し側が判断)
    public static func excludeOrRepairBlankScreenWorkers(
        _ workers: [RunWorker], log: (String) -> Void) async -> BlankScreenTriage {
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
        let outcomes = await withTaskGroup(of: (index: Int, repaired: Bool)?.self,
                                           returning: [(index: Int, repaired: Bool)].self) { group in
            for (index, worker) in candidates {
                group.addTask {
                    guard let serial = worker.connection.serial else { return nil }
                    guard await AndroidHealthProbe.isPersistentlyBlank(
                        serial: serial, samples: 2, intervalMs: 1_500) else { return nil }
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
        var repairedLabels = outcomes.sorted(by: { $0.index < $1.index })
            .filter(\.repaired).map { workers[$0.index].label }
        for label in repairedLabels {
            log("🔧 \(label): 画面凍結(blank-screen)を sleep/wake で修復しました")
        }
        let stubbornIndices = outcomes.filter { !$0.repaired }.map(\.index).sorted()
        guard !stubbornIndices.isEmpty else {
            return BlankScreenTriage(workers: workers, repaired: repairedLabels, excluded: [])
        }

        // sleep/wake 不発の難治型を guest reboot で本 run 内に復帰させる。1台ずつ直列に処理する
        // (複数台の同時ブート描画は凍結そのもののトリガ=別個体を巻き込みうる。実測 2026-07-25)。
        // 該当は通常 0〜1台のため直列でも run 開始の遅延は reboot 1回ぶんに収まる
        var excludedIndices: Set<Int> = []
        for index in stubbornIndices {
            let worker = workers[index]
            guard let serial = worker.connection.serial else {
                excludedIndices.insert(index)
                log("⚠️ \(worker.label): 画面が白化(blank-screen)していますが serial 不明で"
                    + "再起動できないためディスパッチから除外します")
                continue
            }
            log("🔁 \(worker.label): 画面凍結が sleep/wake で直らないため guest を再起動します"
                + "(ブート完了まで最大 \(Int(blankRebootTimeoutSeconds))s 待機。この run で使用します)")
            // ブート完了が確認できない個体は blank 再判定に進めず除外する: 再起動中は screencap 取得
            // 自体が失敗し、probeBlank はそれを「非 blank」(誤除外しない安全側)に倒すため、
            // 判定に掛けるとブート途中の個体を「復帰した」と誤認して run に載せてしまう
            guard await rebootGuest(serial: serial, timeout: blankRebootTimeoutSeconds) else {
                excludedIndices.insert(index)
                log("⚠️ \(worker.label): guest 再起動のブート完了を確認できないため"
                    + "ディスパッチから除外します")
                continue
            }
            if await !AndroidHealthProbe.isPersistentlyBlank(serial: serial, samples: 2,
                                                             intervalMs: 1_500) {
                repairedLabels.append(worker.label)
                log("✅ \(worker.label): guest 再起動で画面凍結が解消しました(この run で使用します)")
                continue
            }
            excludedIndices.insert(index)
            log("⚠️ \(worker.label): guest 再起動でも画面が白化したままのためディスパッチから除外します")
        }
        guard !excludedIndices.isEmpty else {
            return BlankScreenTriage(workers: workers, repaired: repairedLabels, excluded: [])
        }
        return BlankScreenTriage(
            workers: workers.enumerated().filter { !excludedIndices.contains($0.offset) }.map(\.element),
            repaired: repairedLabels,
            excluded: excludedIndices.sorted().map { workers[$0].label })
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

    /// Android ワーカーのみ構築(serial 照合+ドライバ生成のみ=数秒)。
    public static func buildAndroidWorkers(resolved: ResolvedProfile) throws -> [RunWorker] {
        try resolved.androidDevices.map { device in
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
            driver: BridgeClient(port: device.port, host: device.host,
                                 physicalUDID: device.physical ? device.udid : nil),
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
            let provisioned = await withTaskGroup(of: [ProvisionedIOSDevice]?.self) { group in
                group.addTask {
                    try? await provisioner.provision(
                        devices: [(device.name, device.spec)],
                        bundleID: iosApp?.bundleID,
                        preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil,
                        log: log)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
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
            if let app = apps[worker.platform], let appPath = app.appPath,
               app.autoInstall || forceThis {
                // 存在確認だけは直列のまま行う: 確定的な順序で早期 throw するため
                // (差分判定・インストールは下の TaskGroup で並列化)
                guard FileManager.default.fileExists(atPath: appPath) else {
                    throw InstallError(message: "パッケージファイルが見つかりません: \(appPath)")
                }
                candidates.append((index, worker, app, appPath))
            } else {
                if forceThis, apps[worker.platform]?.appPath == nil {
                    safeLog("⚠️ \(worker.label): Wipe Data 後の再インストールに appPath が必要です"
                        + "(apps/ の appPath 未指定)")
                }
                passthrough.append((index, worker))
            }
        }
        guard !candidates.isEmpty else { return workers }

        // N は差分判定前の候補数(判定した結果スキップになるものも含む数)
        log("→ アプリを確認・インストール(\(candidates.count) デバイス)...")

        let installed = await withTaskGroup(of: (Int, RunWorker?).self,
                                            returning: [(Int, RunWorker)].self) { group in
            for (index, worker, app, appPath) in candidates {
                group.addTask {
                    // 差分スキップ: インストール済み内容がパッケージファイルと同一なら入れ直さない
                    if installedIsCurrent(worker: worker, app: app, appPath: appPath) {
                        safeLog("→ \(worker.label): インストール済みアプリが最新のためスキップ(autoInstall)")
                        return (index, worker)
                    }
                    do {
                        try await worker.driver.install(packagePath: appPath)
                        if worker.platform == "ios", let udid = worker.connection.udid {
                            InstalledAppCheck.recordInstalled(udid: udid, bundleID: app.bundleID,
                                                             appPath: appPath)
                        }
                        safeLog("✅ \(worker.label): インストール完了")
                        return (index, worker)
                    } catch {
                        safeLog("❌ \(worker.label): インストール失敗のため離脱 — "
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
            throw InstallError(message: "全ワーカーがインストールに失敗しました")
        }
        return result
    }
}
