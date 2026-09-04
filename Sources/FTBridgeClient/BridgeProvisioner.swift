// 実行プロファイルの iOS デバイス指定 → 稼働ブリッジの照合・不足分の起動。
// 稼働中ブリッジのスキャン(/status)と .fleetest/bridge-<port>.pid を唯一の状態源として、
// 同時に動く他プロセスのブリッジ管理と競合しないポート割当を行う。

import Foundation
import FTCore

public struct ProvisionedIOSDevice: Sendable {
    /// マシンプロファイル上の論理名(例: simulator1)
    public let name: String
    public let udid: String
    public let simulatorName: String
    /// 主ブリッジのポート(inapp/xcuitest)。engine=hybrid のとき in-app ブリッジのポート
    public let port: UInt16
    /// 駆動エンジン("xcuitest" / "inapp" / "hybrid")。DriverConnection 経由でサブプロセスへ伝える
    public let engine: String
    /// engine=hybrid のフォールバック用 XCUITest ブリッジのポート(hybrid 以外は nil)
    public let xcuiPort: UInt16?
    /// 実機か(kind=physical)。simctl 依存の経路を止める分岐に使う
    public let physical: Bool
    /// ブリッジへの到達先ホスト。シミュレータは 127.0.0.1、実機は LAN IP か iproxy のループバック
    public let host: String

    public init(name: String, udid: String, simulatorName: String, port: UInt16,
                engine: String, xcuiPort: UInt16? = nil,
                physical: Bool = false, host: String = BridgeEndpoint.loopbackHost) {
        self.name = name
        self.udid = udid
        self.simulatorName = simulatorName
        self.port = port
        self.engine = engine
        self.xcuiPort = xcuiPort
        self.physical = physical
        self.host = host
    }
}

public enum BridgeProvisionerError: Error, LocalizedError {
    case noFreePort(scanned: ClosedRange<UInt16>)
    /// waitUntilReady() が失敗した場合(後始末として起動済みプロセス/pidファイルは停止済み)
    case notReady(port: UInt16, underlying: Error)
    /// engine="inapp" のブリッジを新規起動するのに bundleID が無い(フォールバックしない=単一実装)
    case inAppNeedsBundleID(name: String)
    /// engine=inapp でアプリ未インストール・preinstallAppPath も無い(provision() が該当デバイスのみ離脱)
    case appNotInstalled(device: String, bundleID: String, udid: String)
    /// preinstallAppPath 指定時の simctl install 自体が失敗した
    case preinstallFailed(device: String, detail: String)
    /// 実機がロックされたまま解除を待ち切った(起動しても SpringBoard に拒否されるので撃たない)
    case deviceLocked(name: String, waited: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .noFreePort(let scanned):
            return "no free port (scanned \(scanned.lowerBound)-\(scanned.upperBound))"
        case .notReady(let port, let underlying):
            // localizedDescription を使う。素の enum を補間すると
            // addressNotAnnounced(port: 8133, logPath: "...", blocker: Optional("..."))
            // のような内部表現がそのままユーザーに出る(実害。2026-07-25)
            return "the bridge did not become ready in time (port \(port)): "
                + underlying.localizedDescription
        case .inAppNeedsBundleID(let name):
            return "\(name): starting an engine=inapp bridge requires the app bundleID. "
                + "Set ios.app in the apps profile"
                + " (paths that do not pass a bundleID, such as device/live, do not support engine=inapp)"
        case .appNotInstalled(_, let bundleID, let udid):
            // device 名は provision() の離脱ログが行頭に付けるためここには含めない
            return "\(bundleID) is not installed, so this device drops out (engine=inapp requires it up front). "
                + "Install it with `xcrun simctl install \(udid) <app>`, "
                + "or set appPath + autoInstall in the apps profile"
        case .deviceLocked(let name, let waited):
            return "\(name) stayed locked for \(Int(waited))s. Unlock the device and run again "
                + "(the runner cannot be launched on a locked device; once it is up it keeps the "
                + "device awake, so this is only needed when the bridge is (re)built)"
        case .preinstallFailed(let device, let detail):
            return "\(device): automatic app install failed:\n\(detail)"
        }
    }
}

/// provision() のプランニング〜起動を跨いだクロスプロセス排他(.fleetest/provision.lock への flock 助言ロック)。
/// ポート予約は pid ファイル存在で判定するが pid ファイルは起動フェーズまで書かれないため、複数の
/// fleetest プロセスが同時に provision すると同じ空きポートを選び bindFailed(48) を起こす。provision()
/// 全体をこのロックで直列化して防ぐ(pid 予約ロジックには手を入れない)。flock はプロセス終了で
/// 自動解放されるためデッドロックしない。1 プロセス内の複数デバイス並列起動は provision 内部で維持される。
public final class ProvisionLock {
    enum LockError: Error { case openFailed(Int32) }
    private let fd: Int32
    private let releaseLock = NSLock()
    private var released = false

    /// stateDir/<lockName> を flock 対象にする。既定は provision.lock(ブリッジ供給用)。
    /// 別用途(例: マシンプロファイル追記)は別 lockName を渡して独立させる。
    public init(stateDir: URL, lockName: String = "provision.lock") throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let path = stateDir.appendingPathComponent(lockName).path
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LockError.openFailed(errno) }
    }

    /// LOCK_EX を取得。取得待ちのブロッキングは別スレッドで行い、async executor を塞がない。
    public func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let fd = self.fd
            DispatchQueue.global().async {
                _ = flock(fd, LOCK_EX)
                cont.resume()
            }
        }
    }

    /// **冪等**。早期解放(ポート確保が済んだ時点)と関数末尾の defer の両方から呼ばれるので、
    /// 2 回目を素通しにしないと close(fd) が無関係な fd を閉じる(fd は再利用される)
    public func release() {
        releaseLock.lock()
        let already = released
        released = true
        releaseLock.unlock()
        guard !already else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}

/// **ポート確保(pid ファイル/記録の書き込み)まで**を数える関門。全ブリッジが「確保済み or 失敗」に
/// なった時点で ProvisionLock を解く —— ready 待ち(実測 7〜28 秒)をロックの外へ出すため。
/// これが無いと、ワーカーが 2 つあっても供給は常に 1 台ずつになる(2026-08-30 の実測: iOS 5 本の
/// 供給 95 秒がすべて直列)。**撃ち漏らすとロックが解放されない**ので、呼び出し側は成否を問わず
/// 必ず 1 回通すこと(BridgeProvisioner.executeDevice の ClaimOnce)
actor PortClaimBarrier {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { remaining = max(0, expected) }

    func claimed() {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func waitAll() async {
        guard remaining > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// 1 ブリッジぶんの合図を 1 回だけ通す小箱。executeBridge は経路が多く(reuse/adopt/launch ×
/// inapp/xcuitest × 実機)、どれかで撃ち漏らすとロックが解放されないままになる
actor ClaimOnce {
    private var fired = false
    private let barrier: PortClaimBarrier

    init(barrier: PortClaimBarrier) { self.barrier = barrier }

    func fire() async {
        guard !fired else { return }
        fired = true
        await barrier.claimed()
    }
}

public struct BridgeProvisioner {
    let repoRoot: URL
    /// 稼働ブリッジのスキャン・自動採番の範囲(既定: 8123〜8154)
    let portRange: ClosedRange<UInt16>

    public init(repoRoot: URL,
                portRange: ClosedRange<UInt16> =
                    BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31)) {
        self.repoRoot = repoRoot
        self.portRange = portRange
    }

    /// 1 デバイス・1 エンジン分の供給プラン。planBridge(副作用なし・await なし)が確定し、
    /// 実処理(停止・起動)は並列実行フェーズが担う。ポート採番はプランニングで確定済み。
    enum EnginePlan {
        case reuse(port: UInt16)
        /// **別プロセスが起動した直後で /status 未応答**の xcuitest ランナーを引き取る
        /// (起動はせず announce を待つだけ)。同一デバイスに 2 本目を立てないための経路で、
        /// 待っても応答しなければ executeBridge がそのランナーを止めて同じポートで起動し直す
        case adopt(port: UInt16)
        /// stopStalePort: 起動前に停止すべき旧版 xcuitest ブリッジのポート。
        /// needsInstall: inapp の autoInstall 差し替え(インストールファイルが更新済み)。
        /// reclaimInApp: このポートに stale な .inapp(ウェッジ等の残留 in-app ブリッジ)が
        /// 既にあり、起動前に simctl terminate で回収する必要がある
        case launch(port: UInt16, needsInstall: Bool, stopStalePort: UInt16?, reclaimInApp: Bool)

        var port: UInt16 {
            switch self {
            case .reuse(let port): return port
            case .adopt(let port): return port
            case .launch(let port, _, _, _): return port
            }
        }
        var isLaunch: Bool {
            if case .launch = self { return true }
            return false
        }
    }

    /// 1 デバイス分のプラン。bridges は実行順(hybrid: inapp → xcuitest の 2 要素、他は 1 要素)
    struct DevicePlan {
        /// 元のデバイス順(結果配列の並びの復元と「最初のエラー」の決定に使う)
        let index: Int
        let name: String
        let sim: SimDeviceInfo
        /// ProvisionedIOSDevice.engine に入る値("hybrid" 含む)
        let engine: String
        let bridges: [(engine: String, plan: EnginePlan)]
    }

    /// 稼働中ブリッジ(シミュレータ UDID が一致)は再利用し、不足分は空きポートで起動する。
    /// engine="inapp" のデバイスは XCUITest ではなく dylib 注入で起動する(bundleID が必要)。
    /// preinstallAppPath: apps プロファイルの appPath+autoInstall が有効なときのアプリパス。
    /// inapp 起動時に未インストールを検出したらその場で simctl install する
    /// (ProfileWorkerFactory.installIfNeeded は provision の後段のため、それより前にここで埋める)。
    /// 流れ: 差分判定(並列)→ プランニング(直列)→ 共有ビルド(直列)→ 起動(デバイス単位で並列)。
    public func provision(devices: [(name: String, spec: DeviceSpec)],
                          bundleID: String? = nil,
                          preinstallAppPath: String? = nil,
                          log: @escaping (String) -> Void) async throws -> [ProvisionedIOSDevice] {
        // 呼び出し側の log(logStderr / print 等)はスレッド安全の契約が無い。
        // 並列フェーズからは必ずこのロック付きラッパーを使う
        let logLock = NSLock()
        let safeLog: (String) -> Void = { message in
            logLock.lock()
            defer { logLock.unlock() }
            log(message)
        }

        // クロスプロセス排他: scan→採番→起動(pid ファイル書き込み)を跨いで直列化する。
        // 他 fleetest プロセスと同じ空きポートを取り合う bindFailed(48) を防ぐ(ProvisionLock 参照)。
        let provisionLock = try ProvisionLock(stateDir: repoRoot.appendingPathComponent(".fleetest"))
        await provisionLock.acquire()
        defer { provisionLock.release() }

        // TTL 自主終了などで残った死んだランナーの pid ファイルを採番前に回収する
        // (assignPort は pid ファイルの有無だけで使用中とみなすため、放置すると採番がドリフトする)
        BridgeLauncher.sweepStalePidFiles(repoRoot: repoRoot)

        let catalog = try SimulatorCatalog.devices()

        // 1. デバイス指定 → シミュレータ実体(UDID)
        var targets: [(name: String, spec: DeviceSpec, sim: SimDeviceInfo)] = []
        for (name, spec) in devices {
            let sim = try SimulatorCatalog.resolve(spec: spec, in: catalog)
            targets.append((name, spec, sim))
        }


        // 2. 稼働中ブリッジのスキャン(ポート → (UDID, engine)。同一 UDID に inapp/xcuitest が
        // 共存する hybrid のため、engine まで見て正しいブリッジを再利用する)
        let running = await scanRunningBridges(catalog: catalog)
        if !running.isEmpty {
            let summary = running.keys.sorted().map(String.init).joined(separator: ", ")
            safeLog("→ Running bridges: port \(summary)")
        }

        // 3. inapp/hybrid の autoInstall 差分判定(バンドル深比較で遅い)を並列に事前評価
        // (プランニングが needsInstall の決定に使うため先に必要)
        let appIsCurrent = await checkInstalledAppCurrency(
            targets: targets, bundleID: bundleID, preinstallAppPath: preinstallAppPath)

        // 3.5. 起動済みだが /status 未応答(= announce 前)の xcuitest ランナー。
        // announce 済みしか映らない running では拾えないため、プロセス引数(-destination id=<UDID>)
        // 照合で別に採る。**別プロセスが起動した直後のランナー**がここに出る = 同じデバイスに
        // 2 本目を立てると OS の 1 デバイス 1 ランナー制約で全滅するので、引き取って待つ
        let startingByUDID = BridgeLauncher
            .portsByUDID(targets.map { $0.sim.udid }, repoRoot: repoRoot)
            .mapValues { $0.filter { !running.keys.contains($0) } }
            .filter { !$0.value.isEmpty }
        if !startingByUDID.isEmpty {
            let summary = startingByUDID.values.flatMap { $0 }.sorted()
                .map(String.init).joined(separator: ", ")
            safeLog("→ Starting bridges (waiting for a response): port \(summary)")
        }

        // 4. プランニング(直列・await なし)。ポート採番の一意性(usedPorts/claimed)のため
        // 全デバイスを必ず直列で処理する
        var usedPorts = Set(running.keys)
        var claimed = Set<UInt16>()  // 1回の provision 内で同じ稼働ブリッジを二重占有しないため
        var plans: [DevicePlan] = []
        // 今このツリーの in-app ソースが作る dylib の digest(再利用判定に使う。
        // 計算できない構成では nil = 従来どおり版と注入先だけで判定する)
        let inappSourceDigest = try? BridgeSourceSet.inApp.digest(repoRoot: repoRoot)
        for (index, target) in targets.enumerated() {
            let engine = target.spec.engine ?? "xcuitest"
            var bridges: [(engine: String, plan: EnginePlan)] = []
            if engine == "hybrid" {
                // in-app(主)+ XCUITest(フォールバック)の2ブリッジ
                bridges.append(("inapp", try planBridge(
                    engine: "inapp", preferred: target.spec.port, name: target.name,
                    sim: target.sim, bundleID: bundleID, appIsCurrent: appIsCurrent,
                    preinstallAppPath: preinstallAppPath,
                    running: running, starting: startingByUDID,
                    inappSourceDigest: inappSourceDigest,
                    claimed: &claimed, usedPorts: &usedPorts)))
                bridges.append(("xcuitest", try planBridge(
                    engine: "xcuitest", preferred: nil, name: target.name,
                    sim: target.sim, bundleID: bundleID, appIsCurrent: appIsCurrent,
                    preinstallAppPath: preinstallAppPath,
                    running: running, starting: startingByUDID,
                    inappSourceDigest: inappSourceDigest,
                    claimed: &claimed, usedPorts: &usedPorts)))
            } else {
                bridges.append((engine, try planBridge(
                    engine: engine, preferred: target.spec.port, name: target.name,
                    sim: target.sim, bundleID: bundleID, appIsCurrent: appIsCurrent,
                    preinstallAppPath: preinstallAppPath,
                    running: running, starting: startingByUDID,
                    inappSourceDigest: inappSourceDigest,
                    claimed: &claimed, usedPorts: &usedPorts)))
            }
            plans.append(DevicePlan(index: index, name: target.name, sim: target.sim,
                                    engine: engine, bridges: bridges))
        }

        // 5. 共有ビルド(直列)。並列起動フェーズより前に必ず済ませる
        try await prepareSharedBuilds(plans: plans, log: safeLog)

        // **ロックはここから「ポート確保が済むまで」しか要らない**。採番と確保(pid ファイル/
        // 記録の書き込み)さえ直列なら bindFailed(48) は防げる —— ready 待ちまで握っていると、
        // ワーカーが 2 つあっても供給が常に 1 台ずつになる(2026-08-30 実測: iOS 5 本の供給 95 秒が
        // すべて直列。同時進行は 2 台のままで、撤回済みの ProvisionBatcher とは別物)。
        // 起動直後で /status 未応答のランナーは、他プロセスからは EnginePlan.adopt が引き取る
        let claimBarrier = PortClaimBarrier(expected: plans.reduce(0) { $0 + $1.bridges.count })
        let earlyRelease = Task {
            await claimBarrier.waitAll()
            provisionLock.release()  // 冪等。末尾の defer と二重に呼ばれてよい
        }
        defer { earlyRelease.cancel() }

        // 6. 起動(デバイス単位で並列。**in-app の新規起動を含むときだけ同時2台に絞る**)。
        // 2026-08-08: フルスイート直後の in-app フェーズ開始(8台同時の terminate→launch+注入)で
        // シミュレータの画面凍結クラスタが同日2回発生した(a11y は応答・描画とタップが停止。
        // 凍結検出器がワーカー除外して完走はする)。Android で対照実験済みの「複数台同時描画」
        // 凍結と同族とみて、一括デバイス起動と同じ「同時2台」に絞る(ユーザー決定の
        // device-up ポリシーと同じ理屈)。再利用/adopt だけの供給は launch を伴わないので
        // 従来どおり全並列 = xcuitest ランナー再利用時の供給時間は変わらない
        let launchesInApp = plans.contains { plan in
            plan.bridges.contains { bridge in
                if case .launch = bridge.plan { return bridge.engine == "inapp" }
                return false
            }
        }
        let launchWidth = launchesInApp ? 2 : plans.count
        let outcomes = await withTaskGroup(
            of: (Int, Result<ProvisionedIOSDevice, Error>).self,
            returning: [Int: Result<ProvisionedIOSDevice, Error>].self) { group in
            var pending = plans.makeIterator()
            func addNext(_ group: inout TaskGroup<(Int, Result<ProvisionedIOSDevice, Error>)>) {
                guard let plan = pending.next() else { return }
                group.addTask {
                    do {
                        let device = try await self.executeDevice(
                            plan: plan, bundleID: bundleID,
                            preinstallAppPath: preinstallAppPath,
                            claimBarrier: claimBarrier, log: safeLog)
                        return (plan.index, .success(device))
                    } catch {
                        return (plan.index, .failure(error))
                    }
                }
            }
            for _ in 0..<max(1, launchWidth) { addNext(&group) }
            var results: [Int: Result<ProvisionedIOSDevice, Error>] = [:]
            for await (index, result) in group {
                results[index] = result
                addNext(&group)
            }
            return results
        }

        // 7. 元のデバイス順に集約。**供給できなかった機はその機だけ離脱させ、残りで走る**。
        //
        // 以前は appNotInstalled 以外を throw していたが、それは**健全な機を道連れにする**:
        // 2026-08-11 のフル E2E では 10台中8台が ready だったのに、残り2台の期限切れで
        // iOS ワーカーが丸ごと失われ、Flutter/RN の 51 本が1本も走らなかった。
        // 「凍結機はレーンから外して残りで走る」(BlankWorkerTriage)と同じ思想へ揃える。
        //
        // **全滅のときだけ throw する**(呼び出し側が run 全体の失敗として扱えるように)。
        let collected = plans.compactMap { plan in
            outcomes[plan.index].map { (name: plan.name, result: $0) }
        }
        // **理由は resolve より前に、1台ずつ全部出す**。`FleetOutcome.resolve` は全滅のとき
        // **最初の1件だけを throw** するので、ここで出しておかないと残りの理由が消える ——
        // 2026-09-04 の調査で、8台が同時に落ちた回の記録が1ポートぶんしか無く、
        // 「全機が同じ理由で死んだのか、別々の理由なのか」を後から言えなかった
        for outcome in collected {
            if case .failure(let error) = outcome.result {
                safeLog("❌ \(outcome.name): \(error.localizedDescription)")
            }
        }
        let resolved = try Self.resolveOutcomes(collected)
        if !resolved.failures.isEmpty {
            // 何台落ちたかを1行で残す(個々の理由は上で出ている)。台数が減ったことは
            // レーン稼働率にも出るので、run の遅さを供給失敗と取り違えないための手掛かり
            safeLog("⚠️ \(resolved.failures.count) device(s) could not be provisioned"
                + " — continuing with \(resolved.devices.count) device(s)")
        }
        return resolved.devices
    }

    /// 供給結果の集約規則。**定義元は `FTCore.FleetOutcome.resolve`**(Android ワーカー構築と
    /// 規則を共有するため。ここは転送するだけ)。
    static func resolveOutcomes<T>(
        _ outcomes: [(name: String, result: Result<T, Error>)]
    ) throws -> (devices: [T], failures: [(name: String, error: Error)]) {
        try FleetOutcome.resolve(outcomes)
    }

    /// autoInstall 付き inapp/hybrid の「インストール済みアプリが最新か」を並列評価(UDID → 最新か)。
    /// InstalledAppCheck はバンドル全バイト深比較でアプリサイズ比例に遅い(installIfNeeded の
    /// 差分スキップと共用)。判定不能・マップ欠落は false 扱い=インストールする安全側
    private func checkInstalledAppCurrency(
        targets: [(name: String, spec: DeviceSpec, sim: SimDeviceInfo)],
        bundleID: String?, preinstallAppPath: String?) async -> [String: Bool] {
        guard let bundleID, let preinstallAppPath else { return [:] }
        let udids = Set(targets.filter {
            let engine = $0.spec.engine ?? "xcuitest"
            return engine == "inapp" || engine == "hybrid"
        }.map { $0.sim.udid })
        guard !udids.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, Bool).self,
                                   returning: [String: Bool].self) { group in
            for udid in udids {
                group.addTask {
                    (udid, InstalledAppCheck.simulatorAppIsCurrent(
                        udid: udid, bundleID: bundleID, appPath: preinstallAppPath))
                }
            }
            var result: [String: Bool] = [:]
            for await (udid, current) in group { result[udid] = current }
            return result
        }
    }

    /// 1 デバイス・1 エンジンのプラン決定。副作用は claimed/usedPorts の更新のみ
    /// (ログ・プロセス操作・await なし=単体テスト可能に保つこと)
    func planBridge(engine: String, preferred: UInt16?, name: String, sim: SimDeviceInfo,
                            bundleID: String?, appIsCurrent: [String: Bool],
                            preinstallAppPath: String?,
                            running: [UInt16: RunningBridge],
                            starting: [String: [UInt16]] = [:],
                            inappSourceDigest: String? = nil,
                            claimed: inout Set<UInt16>,
                            usedPorts: inout Set<UInt16>) throws -> EnginePlan {
        // autoInstall(preinstallAppPath)付き inapp は「インストールファイルが更新されているとき
        // だけ」install+注入起動で差し替える(install は起動中アプリ=in-app ブリッジを終了させる
        // ため、後段の installIfNeeded で入れ直す順序は不可=あちらは inapp/hybrid をスキップする)。
        // 最新なら稼働中ブリッジを再利用して install も relaunch も省く。
        var inappNeedsInstall = false
        if engine == "inapp", preinstallAppPath != nil, bundleID != nil {
            inappNeedsInstall = !(appIsCurrent[sim.udid] ?? false)
        }
        // 稼働ブリッジと供給対象 sim の相関: 通常は udid。ただし同名 sim が複数 booted だと
        // detectRunningBridges が udid を nil に落とす。その場合は名前で相関し、同一デバイスへの
        // 二重ブリッジ起動を避ける(同名 sim 同士は構成が同じで実害小)。
        func sameDevice(_ rb: RunningBridge) -> Bool {
            rb.udid == sim.udid || (rb.udid == nil && rb.name == sim.name)
        }
        // xcuitest は protocolVersion が現行値と一致するときだけ再利用する(旧ビルドは 404 等の
        // 不整合を招くため。inapp は毎プロビジョンで再ビルド・再注入なので判定しない)。
        // inapp は**注入先アプリが一致するときだけ**再利用する。別アプリの SUT が同じデバイス群を
        // 使い回すと、アプリ違いのブリッジを掴む → 最初のシナリオが対象アプリを前面化した時点で
        // 旧アプリが suspend → probe が無応答 → フォールバックが「注入先 = 今回のアプリ」と誤認 →
        // 旧アプリが握ったままのポートで relaunch → bind 失敗し、以降のリクエストは suspend した
        // 旧ブリッジへ(TCP 受理・HTTP 無応答の 20s タイムアウト)。2026-07-23 に E2E → E2E-iOS の
        // 連続実行で 14/20 失敗として実害化した連鎖の根がここ
        // **inapp は dylib の出所も一致しないと再利用しない**。版一致だけでは
        // 「版を上げ忘れた変更」も「決定するプロセスが1ビルド古い場合」も素通りし、**変更が
        // 1度も実行されないまま緑になる**(実測は InAppBridgeState 冒頭)。digest はその場の
        // ソースから計算するのでどちらにも掛かる。**計算できないとき(nil)は従来どおり**
        // = 判定材料が無いことを理由に毎回建て直さない
        func inappSourcesMatch(_ rb: RunningBridge) -> Bool {
            guard engine == "inapp", let current = inappSourceDigest else { return true }
            return rb.sourceDigest == current
        }
        if !(engine == "inapp" && inappNeedsInstall),
           let port = running.first(where: {
            sameDevice($0.value) && $0.value.engine == engine && !claimed.contains($0.key)
                // inapp も版一致を要求する(旧 dylib のまま suspend/常駐しているブリッジを
                // 再利用すると新エンドポイントが 404 になり、フォールバックも効かない)
                && $0.value.protocolVersion == BridgeAPI.bridgeProtocolVersion
                && (engine != "inapp" || $0.value.sessionBundleID == bundleID)
                && inappSourcesMatch($0.value)
           })?.key {
            claimed.insert(port)
            return .reuse(port: port)
        }
        // 起動中(announce 前)の xcuitest ランナーがこのデバイスに居るなら引き取る。
        // pid ファイルを持つのは xcuitest だけ(inapp は .inapp 状態ファイル)なので engine は自明。
        // **新しい空きポートで 2 本目を立てない**のがこの分岐の目的
        if engine == "xcuitest",
           let port = (starting[sim.udid] ?? []).first(where: { !claimed.contains($0) }) {
            claimed.insert(port)
            usedPorts.insert(port)
            return .adopt(port: port)
        }
        // 再利用できない同一 UDID の旧ブリッジは止めてから新規起動する
        // (放置するとポートを握ったまま残り、xcuitest は /status が旧版のまま応答し続け、
        // inapp は対象アプリ前面化で suspend したゾンビになる)。
        // 停止は並列実行フェーズが行い、ここは採番状態の更新だけ
        var stopStalePort: UInt16?
        if engine == "xcuitest", let stale = running.first(where: {
            sameDevice($0.value) && $0.value.engine == "xcuitest" && !claimed.contains($0.key)
                && $0.value.protocolVersion != BridgeAPI.bridgeProtocolVersion
        }) {
            claimed.insert(stale.key)
            usedPorts.remove(stale.key)
            stopStalePort = stale.key
        }
        // 別アプリに注入された・または旧版のままの同一デバイスの inapp ブリッジ
        // (上の再利用条件から漏れたもの)
        if engine == "inapp", let stale = running.first(where: {
            sameDevice($0.value) && $0.value.engine == "inapp" && !claimed.contains($0.key)
                && ($0.value.sessionBundleID != bundleID
                    || $0.value.protocolVersion != BridgeAPI.bridgeProtocolVersion
                    || !inappSourcesMatch($0.value))
        }) {
            claimed.insert(stale.key)
            stopStalePort = stale.key
        }
        let port = try assignPort(preferred: preferred, used: &usedPorts,
                                  ignoringPidFileFor: stopStalePort)
        claimed.insert(port)
        // in-app の新規起動には注入対象アプリの bundleID が要る。無ければ XCUITest に
        // フォールバックせず明示エラー(単一実装。device/live 等は engine=inapp 非対応)
        if engine == "inapp", bundleID == nil {
            throw BridgeProvisionerError.inAppNeedsBundleID(name: name)
        }
        // assignPort が .inapp 残留ポートを回収して返した場合(preferred 経由も含む)。
        // executeBridge が起動前に simctl terminate する
        let inappStatePath = InAppBridgeState.url(
            stateDir: repoRoot.appendingPathComponent(".fleetest"), port: port)
        let reclaimInApp = FileManager.default.fileExists(atPath: inappStatePath.path)
        return .launch(port: port, needsInstall: inappNeedsInstall, stopStalePort: stopStalePort,
                       reclaimInApp: reclaimInApp)
    }

    /// 全デバイス共有のビルド成果物(in-app dylib / xcuitest の xctestrun)は、並列起動フェーズの
    /// 前にここで必ず直列に済ませる(並列に buildIfNeeded / buildForTesting が走ると出力が競合する)。
    /// xctestrun 不在時の build-for-testing もここへ前倒し(起動フェーズの startDetached では作らない)
    private func prepareSharedBuilds(plans: [DevicePlan],
                                     log: @escaping (String) -> Void) async throws {
        let launches = plans.flatMap { plan in
            plan.bridges.filter { $0.plan.isLaunch }
                .map { (sim: plan.sim, engine: $0.engine, port: $0.plan.port) }
        }
        let inapp = launches.first { $0.engine == "inapp" }
        // **シミュレータと実機で xctestrun は別物**(SDK も DerivedData も分かれている)。
        // 種別ごとに 1 つずつビルドする。first で 1 つだけ選ぶと、混在 run で選ばれなかった側が
        // startDetached の findXCTestRun で xctestrunNotFound になる
        let xcuiByKind = Dictionary(
            grouping: launches.filter { $0.engine != "inapp" }, by: { $0.sim.physical })
            .compactMap { $0.value.first }
        guard inapp != nil || !xcuiByKind.isEmpty else { return }
        try await Task.detached(priority: .userInitiated) {
            if let inapp {
                // dylib は全デバイス共有(udid/port は buildIfNeeded では未使用)
                try InAppLauncher(repoRoot: repoRoot, udid: inapp.sim.udid,
                                  port: inapp.port).buildIfNeeded()
            }
            for xcui in xcuiByKind {
                // xctestrun は同種別の全ポート共有(startDetached がポート注入コピーを作る)
                let launcher = BridgeLauncher(repoRoot: repoRoot, device: xcui.sim.udid,
                                              port: xcui.port, physical: xcui.sim.physical)
                try launcher.generateProjectIfNeeded()
                let existing = try launcher.findXCTestRun()
                let rebuild = existing.map {
                    BridgeLauncher.runnerNeedsRebuild(
                        repoRoot: repoRoot, xctestrun: $0,
                        signing: launcher.currentSigningFingerprint()) } ?? false
                // **ビルドを始める前に**ロックを知らせる(ビルド自体に解除は要らないので待たない
                // = 数分の間に解除してもらえれば、起動時に待たずに済む)
                if xcui.sim.physical, existing == nil || rebuild,
                   IOSPhysicalDeviceLock.query(udid: xcui.sim.udid) == .locked {
                    log("⏳ \(xcui.sim.name) is locked — unlock it while this builds "
                        + "(the runner cannot be launched on a locked device).")
                }
                if existing == nil {
                    log("→ build-for-testing (for \(xcui.sim.physical ? "a physical device" : "the simulator")"
                        + "; the first run takes several minutes)...")
                    try launcher.buildForTesting()
                } else if rebuild {
                    // ソース変更後の旧 xctestrun を起動し続けない(BridgeLauncher.runnerNeedsRebuild 参照)
                    log("→ Runner sources changed — re-running build-for-testing...")
                    try launcher.buildForTesting()
                }
            }
        }.value
    }

    /// 1 デバイス分のプラン実行。デバイス間は並列だが、同一デバイス内のブリッジ
    /// (hybrid の inapp → xcuitest)は同一シミュレータへの simctl 競合を避けるため直列。
    /// inapp が失敗したら xcuitest は実行しない(直列版と同じ)
    private func executeDevice(plan: DevicePlan, bundleID: String?, preinstallAppPath: String?,
                               claimBarrier: PortClaimBarrier,
                               log: @escaping (String) -> Void) async throws -> ProvisionedIOSDevice {
        var ports: [UInt16] = []
        for bridge in plan.bridges {
            // **成否を問わず必ず 1 回通す**(撃ち漏らすと ProvisionLock が解放されない)。
            // executeBridge の中でも確保直後に撃つが、経路の取りこぼしをここで埋める
            let claim = ClaimOnce(barrier: claimBarrier)
            do {
                ports.append(try await executeBridge(
                    engine: bridge.engine, plan: bridge.plan, name: plan.name, sim: plan.sim,
                    bundleID: bundleID, preinstallAppPath: preinstallAppPath,
                    claimed: { await claim.fire() }, log: log))
                await claim.fire()
            } catch {
                await claim.fire()
                throw error
            }
        }
        return ProvisionedIOSDevice(
            name: plan.name, udid: plan.sim.udid, simulatorName: plan.sim.name,
            port: ports[0], engine: plan.engine,
            xcuiPort: ports.count > 1 ? ports[1] : nil,
            physical: plan.sim.physical,
            // 再利用(.reuse)経路でも宛先を復元できるよう記録ファイルを唯一の正にする
            host: BridgeEndpoint.load(port: ports[0], repoRoot: repoRoot).host)
    }

    /// 1 ブリッジ分のプラン実行(ポート採番・再利用判定はプランニングで確定済み)
    /// - claimed: **ポートを確保した(pid ファイル/記録を書いた)直後**に撃つ。これで
    ///   ProvisionLock が解け、ready 待ちは他ワーカーと並行になる。再利用・引き取りは新しく
    ///   確保しないので即座に撃つ
    private func executeBridge(engine: String, plan: EnginePlan, name: String, sim: SimDeviceInfo,
                               bundleID: String?, preinstallAppPath: String?,
                               claimed: @escaping @Sendable () async -> Void,
                               log: @escaping (String) -> Void) async throws -> UInt16 {
        switch plan {
        case .reuse(let port):
            await claimed()
            log("✅ \(name): reusing the running \(engine) bridge (port \(port), \(sim.name))")
            return port
        case .adopt(let port):
            await claimed()
            // 別プロセスが起動した直後のランナー。起動はせず announce だけ待つ
            log("→ \(name): taking over the starting \(engine) bridge (port \(port), \(sim.name))...")
            let launcher = BridgeLauncher(repoRoot: repoRoot, device: sim.udid, port: port,
                                          physical: sim.physical)
            // 起動した側(前回の executeBridge、あるいは別プロセス)は自分の budget を待ち切った
            // 時点で諦めている。budget 以上生きているのに announce していないランナーは、これ以上
            // 待っても announce しない孤児なので、待たずに止めて建て直す
            func stopAndRelaunch() async throws -> UInt16 {
                try? await launcher.stopAndWait()
                return try await executeBridge(
                    engine: engine,
                    plan: .launch(port: port, needsInstall: false,
                                  stopStalePort: nil, reclaimInApp: false),
                    name: name, sim: sim, bundleID: bundleID,
                    preinstallAppPath: preinstallAppPath, claimed: claimed, log: log)
            }
            let elapsed = launcher.runnerElapsed()
            // .restart は elapsed != nil のときしか返らない(decide 参照)ので force unwrap は安全
            if StartingRunnerVerdict.decide(elapsed: elapsed, budget: BridgeLauncher.startupTimeoutSeconds) == .restart {
                log("⚠️ \(name): the starting bridge on port \(port) has been alive for \(Int(elapsed!))s "
                    + "without answering — longer than the startup budget "
                    + "(\(Int(BridgeLauncher.startupTimeoutSeconds))s), so the process that launched it has "
                    + "already given up; stopping and restarting it")
                return try await stopAndRelaunch()
            }
            do {
                try await launcher.waitUntilReady(host: BridgeEndpoint(port: port).host,
                                                  log: { log("\(name): \($0)") })
                log("✅ \(name): took over the \(engine) bridge that was starting (port \(port))")
                return port
            } catch {
                // 親を失ったゾンビ(再起動・kill で announce しないまま残ったランナー)。
                // 放置すると同じデバイスで何度でも待たされるので、止めてから同じポートで立て直す
                log("⚠️ \(name): the starting bridge (port \(port)) is not responding — stopping and restarting it")
                return try await stopAndRelaunch()
            }
        case .launch(let port, let needsInstall, let stopStalePort, let reclaimInApp):
            let stateDir = repoRoot.appendingPathComponent(".fleetest")
            if let stopStalePort {
                // 止める手段は記録の有無で決める(StaleBridgeStop。純粋関数でテスト固定):
                // inapp(.inapp あり)は simctl terminate / xcuitest(.pid あり)は stopAndWait /
                // **どちらの記録も無い**= 別クローンが起動した・記録前に中断された in-app ブリッジは
                // ポートの LISTEN 実体を PortHolder で止める(以前はここを .pid 経路へ流して
                // 「no .fleetest/bridge.pid」で止めそこね、掴んだままのポートと衝突していた)
                let stalePath = InAppBridgeState.url(stateDir: stateDir, port: stopStalePort)
                let pidPath = stateDir.appendingPathComponent("bridge-\(stopStalePort).pid")
                switch StaleBridgeStop.decide(
                    hasInAppRecord: FileManager.default.fileExists(atPath: stalePath.path),
                    hasPidFile: FileManager.default.fileExists(atPath: pidPath.path)) {
                case .terminateRecordedInApp:
                    log("→ \(name): terminating an in-app bridge injected into a different app (port \(stopStalePort)) and restarting")
                    InAppBridgeState.terminateAndRemove(at: stalePath)
                case .stopRunner:
                    log("→ \(name): stopping a bridge from an older build (port \(stopStalePort)) and restarting")
                    do {
                        try await BridgeLauncher(repoRoot: repoRoot, device: sim.udid,
                                                 port: stopStalePort,
                                                 physical: sim.physical).stopAndWait()
                    } catch {
                        log("⚠️ \(name): failed to stop the stale bridge (port \(stopStalePort)): \(error.localizedDescription)")
                    }
                case .stopPortHolder:
                    switch PortHolder.stopIfOwnedBridge(
                        port: stopStalePort, stateDir: stateDir,
                        derivedDataPath: stateDir.appendingPathComponent("DerivedData")) {
                    case .stopped(let holder):
                        log("🔧 \(name): stopped an untracked bridge from an older build on port \(stopStalePort) (\(holder))")
                    case .notFound:
                        log("→ \(name): the older bridge on port \(stopStalePort) is no longer listening")
                    case .foreign(let holder):
                        log("⚠️ \(name): could not stop the older bridge on port \(stopStalePort) — it is held by \(holder)")
                    }
                }
            }
            // **これから使うポートを今 LISTEN しているプロセス**を、記録の有無に関わらず確かめる。
            // 以前は stale .inapp の記録があるときだけ見ていたが、記録の無い残骸(別クローン・
            // 別デバイスで背面に回った in-app ブリッジ)は /status に答えないので scan に映らず、
            // 採番では空きに見える(全シミュレータはホストの loopback を共有するのでポートは台を跨いで
            // 一意)。そのまま注入すると bind できず「did not respond in time」で落ち、原因が残骸だと
            // 分からない(受け手報告 2026-08-22/23)。
            // 記録の有無に関わらず、実際に LISTEN されている場合のみ占有者の実体を確認して停止する
            // (記録どおりに blind に terminate すると同アプリの別ポートの現役ブリッジを誤殺する実害あり)
            switch PortHolder.stopIfOwnedBridge(
                port: port, stateDir: stateDir,
                derivedDataPath: stateDir.appendingPathComponent("DerivedData")) {
            case .stopped(let holder):
                log("🔧 \(name): stopped a leftover bridge holding port \(port) (\(holder))")
            case .notFound:
                break
            case .foreign(let holder):
                // xcuitest は bindFailed → portInUse 経路が拾って明示エラーになる。
                // **in-app には bind 失敗の検知が無い**(注入先アプリの中で黙って失敗する)ので、
                // 撃たずにここで原因を名指しして落とす
                if engine == "inapp" {
                    throw BridgeProvisionerError.notReady(
                        port: port, underlying: LauncherError.portInUse(port: port, holder: holder))
                }
                log("⚠️ \(name): port \(port) is held by an unrelated process (\(holder))")
            }
            if reclaimInApp {
                try? FileManager.default.removeItem(
                    at: InAppBridgeState.url(stateDir: stateDir, port: port))
            }
            log("→ \(name): starting the \(engine) bridge (port \(port), \(sim.name) \(sim.os))...")
            if engine == "inapp" {
                // planBridge が bundleID 必須を検証済み(ここは保険)
                guard let bundleID else {
                    throw BridgeProvisionerError.inAppNeedsBundleID(name: name)
                }
                // 起動前に、同一デバイスの再利用対象外 in-app ゾンビを掃除する(累積の発生源対策)。
                // in-app ブリッジは対象アプリが背面化で suspend されると /status 無応答になり
                // scanRunningBridges に映らない=再利用も stale 停止もされず、inapp run のたびに
                // 1本ずつ .inapp 状態ファイルが積もる(実測: 連続 inapp で 6→12)。放置すると
                // ポート範囲を食い潰し・シミュレータのリソースを消費する(scan の遅延自体は
                // status(timeout:) 化で別途緩和済み)。
                reclaimInAppOrphans(udid: sim.udid, exceptPort: port, name: name, log: log)
                let launcher = InAppLauncher(repoRoot: repoRoot, udid: sim.udid, port: port)
                // dylib ビルドは prepareSharedBuilds で完了済み(ここで buildIfNeeded すると並列で競合)
                try await Task.detached(priority: .userInitiated) {
                    try launcher.ensureBooted()  // simctl launch はブート済み前提(install も同様)
                    try self.ensureAppInstalled(deviceName: name, sim: sim, bundleID: bundleID,
                                                preinstallAppPath: preinstallAppPath,
                                                needsInstall: needsInstall, log: log)
                }.value
                do {
                    // **in-app は relaunch の中で記録の書き込みと ready 待ちが分かれていない**ので、
                    // 確保の合図は戻ってから(= この経路はロックの短縮が効かない)
                    try await launcher.relaunch(bundleID: bundleID)
                    await claimed()
                } catch {
                    // 起動したアプリを残さない(ブリッジの無いアプリが前面に残ると次の run でも
                    // 残骸になる)。記録は relaunch が ready 前に書いているのでここで消す
                    launcher.terminate(bundleID: bundleID)
                    try? FileManager.default.removeItem(
                        at: InAppBridgeState.url(stateDir: stateDir, port: port))
                    // **原因を名指しする**: 同じポートを別プロセスが掴んでいたなら、それが答え。
                    // 「応答が無い」だけでは残骸が原因だと分からず、人がノートに書き残して初めて
                    // 次の人が気付ける状態だった(受け手報告)
                    if let holder = PortHolder.describe(port: port) {
                        throw BridgeProvisionerError.notReady(
                            port: port, underlying: LauncherError.portInUse(port: port, holder: holder))
                    }
                    throw error
                }
            } else {
                let launcher = BridgeLauncher(repoRoot: repoRoot, device: sim.udid, port: port,
                                              physical: sim.physical)
                // **起動はロックされた端末では拒否される**。ここで解除を待つ(待ちきれなくても
                // 起動は試みる)。待たずに撃つと deviceprep が `Unlock <name> to Continue` の
                // まま留まり、`Failed to resume target process` でセッションごと死ぬ
                if sim.physical {
                    let state = await IOSPhysicalDeviceLock.waitForUnlock(
                        udid: sim.udid, deviceName: name,
                        timeout: BridgeLauncher.startupTimeoutSeconds,
                        log: { log("\(name): \($0)") })
                    // **ロックのままなら撃たない**: 起動しても deviceprep に拒否され、締切ぶん
                    // (もう 180 秒)待ってから同じ理由で落ちるだけ。unknown は促していないので通す
                    if state == .locked {
                        throw BridgeProvisionerError.deviceLocked(
                            name: name, waited: BridgeLauncher.startupTimeoutSeconds)
                    }
                }
                // xctestrun の存在は prepareSharedBuilds が保証済み(不在なら xctestrunNotFound が
                // そのまま届く。ここで buildForTesting はしない=並列で二重ビルドさせない)
                try await Task.detached(priority: .userInitiated) {
                    try launcher.generateProjectIfNeeded()
                    try launcher.startDetached()
                }.value
                // **ここでポートは確保済み**(startDetached が pid ファイルを書く)。以降の
                // ready 待ちはロックの外でよい = 他ワーカーの供給と並行に進む
                await claimed()
                // 実機はデバイス内ループバックに届かない。/status を叩く前に到達手段
                // (LAN の宛先解決 or iproxy の USB トンネル)を確立して endpoint を記録する
                var endpoint = BridgeEndpoint(port: port)
                if sim.physical {
                    do {
                        endpoint = try await IOSDeviceTransport.establish(
                            port: port, deviceUDID: sim.udid, repoRoot: repoRoot,
                            wired: sim.wired, log: { log("\(name): \($0)") })
                    } catch {
                        // 到達手段が確立できなくても xcodebuild は実機で走り続ける。止めないと
                        // 失敗のたびに常駐ランナーとポートが実機に溜まる(実測で 5 本残った)
                        try? launcher.stop()
                        throw error
                    }
                    log("→ \(name): connecting to the physical-device bridge at \(endpoint.host):\(port)")
                }
                do {
                    try await launcher.waitUntilReady(host: endpoint.host,
                                                      log: { log("\(name): \($0)") })
                } catch let error as LauncherError {
                    guard case .portInUse = error else {
                        try? launcher.stop()
                        throw BridgeProvisionerError.notReady(port: port, underlying: error)
                    }
                    // 失敗した試行の pid ファイルを掃除してから占有者を特定・後始末を試みる
                    try? launcher.stop()
                    let outcome = PortHolder.stopIfOwnedBridge(
                        port: port, stateDir: repoRoot.appendingPathComponent(".fleetest"),
                        derivedDataPath: launcher.derivedDataPath)
                    let description: String
                    switch outcome {
                    case .stopped(let d):
                        description = d
                    case .foreign(let d):
                        throw BridgeProvisionerError.notReady(
                            port: port, underlying: LauncherError.portInUse(port: port, holder: d))
                    case .notFound:
                        throw BridgeProvisionerError.notReady(
                            port: port, underlying: LauncherError.portInUse(port: port, holder: nil))
                    }
                    log("🔧 \(name): stopping a leftover process on port \(port) and retrying (\(description))")
                    // 1 回だけ同一ポートで再試行する(無限ループ禁止。再失敗はここで諦める)
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try launcher.startDetached()
                        }.value
                        try await launcher.waitUntilReady()
                    } catch {
                        try? launcher.stop()
                        throw BridgeProvisionerError.notReady(port: port, underlying: error)
                    }
                } catch {
                    // 後始末せずに投げると assignPort がこのポートを使用中とみなし続け採番がずれていく
                    try? launcher.stop()
                    throw BridgeProvisionerError.notReady(port: port, underlying: error)
                }
            }
            log("✅ \(name): \(engine) bridge ready (port \(port))")
            return port
        }
    }

    /// 同一 UDID の再利用対象外 in-app ゾンビ(.inapp 状態ファイルは残るが scanRunningBridges には
    /// 映らない suspend 個体)を、新しい in-app ブリッジを起動する前に掃除する。exceptPort(今回
    /// 起動するポート)は除外する。
    /// 誤殺防止: terminate(bundleID) で blind に止めると同アプリの別ポートの現役ブリッジを誤殺して
    /// 実行中ワーカーが連鎖死する実害があったため(reclaimInApp のコメント参照)、ここでも
    /// PortHolder(実際に LISTEN している場合のみ占有者を確認して停止・無人なら記録削除)を使う。
    /// scan に映らない=同一 provision 内で再利用中ではない(launch 側でのみ呼ぶ)ため、掃除しても
    /// 稼働中ブリッジは殺さない。ファイルは全ケースで削除する(stale 記録を残さない)。
    private func reclaimInAppOrphans(udid: String, exceptPort: UInt16, name: String,
                                    log: (String) -> Void) {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "inapp" {
            let portStr = entry.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "bridge-", with: "")
            guard let orphanPort = UInt16(portStr), orphanPort != exceptPort,
                  let state = InAppBridgeState.read(at: entry), state.udid == udid else { continue }
            if case .stopped(let holder) = PortHolder.stopIfOwnedBridge(
                port: orphanPort, stateDir: stateDir,
                derivedDataPath: stateDir.appendingPathComponent("DerivedData")) {
                log("🔧 \(name): stopped a leftover in-app bridge on the same device (port \(orphanPort)) (\(holder))")
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// inapp の注入起動(simctl launch)はアプリのインストールが前提。autoInstall
    /// (preinstallAppPath)有りなら needsInstall(=installedAppIsCurrent の否定)のときだけ
    /// インストールする。無しなら存在確認のみ行い、未インストールは appNotInstalled を投げる
    /// (provision() が該当デバイスだけ離脱させて続行する)。
    private func ensureAppInstalled(deviceName: String, sim: SimDeviceInfo, bundleID: String,
                                    preinstallAppPath: String?, needsInstall: Bool,
                                    log: @escaping (String) -> Void) throws {
        if let preinstallAppPath {
            guard needsInstall else { return }
            log("→ \(deviceName): installing \(bundleID) (autoInstall: the contents changed)...")
            let install = try Shell.run(["xcrun", "simctl", "install", sim.udid, preinstallAppPath])
            guard install.status == 0 else {
                throw BridgeProvisionerError.preinstallFailed(device: deviceName, detail: install.tail)
            }
            log("✅ \(deviceName): install complete")
            return
        }
        let check = try Shell.run(["xcrun", "simctl", "get_app_container", sim.udid, bundleID])
        guard check.status == 0 else {
            throw BridgeProvisionerError.appNotInstalled(
                device: deviceName, bundleID: bundleID, udid: sim.udid)
        }
    }

    /// 稼働中ブリッジ 1 つの識別情報(接続先 UDID・engine 種別)
    struct RunningBridge: Sendable {
        let udid: String?
        /// /status が返したデバイス名。udid が同名複数で nil に落ちたときの相関フォールバックに使う。
        let name: String?
        let engine: String
        /// BridgeAPI.bridgeProtocolVersion。旧ブリッジは nil(xcuitest の再利用判定に使う)。
        let protocolVersion: Int?
        /// /status の sessionBundleID。in-app ブリッジは注入先アプリ固有のため、
        /// 再利用は「同じアプリに注入済み」のときだけ許す(inapp の再利用判定に使う)。
        let sessionBundleID: String?
        /// **注入済み dylib の出所**(`.inapp` 状態ファイルに残した BridgeSourceSet.inApp の digest)。
        /// nil = 旧版が書いた記録 or 記録なし = 出所不明。inapp の再利用判定に使う
        let sourceDigest: String?

        init(udid: String?, name: String?, engine: String, protocolVersion: Int?,
             sessionBundleID: String?, sourceDigest: String? = nil) {
            self.udid = udid
            self.name = name
            self.engine = engine
            self.protocolVersion = protocolVersion
            self.sessionBundleID = sessionBundleID
            self.sourceDigest = sourceDigest
        }
    }

    /// provision の再利用判定用。engine・protocolVersion は /status のもの(旧ブリッジはどちらも
    /// nil。旧ブリッジは engine を "xcuitest" 扱いにするが protocolVersion は nil のままにして
    /// 再利用不可と判定させる)。
    /// 注意: /status 無応答のゾンビは映らない。停止用途には BridgeLauncher.stopMatching を使う
    /// (HTTP でなく pid ファイル+プロセス引数の UDID 照合)。**ゾンビ側は provision() の
    /// startingByUDID(同じくプロセス引数照合)が拾って .adopt → 同ポートで建て直すので、
    /// ここに映らないこと自体は穴ではない** —— 穴だったのは「映っているのに端末を特定できない」
    /// ほう(下の resolveUDID)。
    func scanRunningBridges(catalog: [SimDeviceInfo]) async -> [UInt16: RunningBridge] {
        await withTaskGroup(of: (UInt16, RunningBridge)?.self,
                            returning: [UInt16: RunningBridge].self) { group in
            for port in portRange {
                group.addTask {
                    // status(timeout:) を明示する(引数なし status() は sessionTimeout=45s を
                    // per-request に上書きするため、init の timeoutSeconds:2 が効かない)。これを怠ると
                    // suspend/ウェッジした孤児ブリッジ(TCP 受理・HTTP 無応答)1本で scan 全体が
                    // 並列でも ~45s 待ち、連続 run が逓減する(2026-07-25 実測 46s→<2s)。
                    // 実機ブリッジは 127.0.0.1 に居ない。establish が残した宛先を使う
                    // (記録が無ければループバック = シミュレータ/Android の既定)
                    let endpoint = BridgeEndpoint.load(port: port, repoRoot: self.repoRoot)
                    let client = BridgeClient(port: port, timeoutSeconds: 2, host: endpoint.host)
                    guard let status = try? await client.status(timeout: 2), status.ready else {
                        return nil
                    }
                    // デバイス名 → UDID(同名の起動中シミュレータが複数なら特定不能 = nil)
                    let booted = catalog.filter { $0.booted && $0.name == status.device }
                    // **引き当ての規則は BridgeDiscovery.resolveUDID の1箇所**。
                    // ここは名前引きしか見ていなかったので、**udid を申告しない実機のブリッジは
                    // 生きていても端末に紐付かず**、planBridge の sameDevice / stopStalePort に
                    // 一度も当たらないまま2本目のランナーが立っていた(1台に2本立てると全滅する)。
                    // status.udid を最優先にしたことで、同名 sim が複数 booted のときに
                    // 名前引きが nil へ落ちていた劣化も同時に解消する
                    let udid = BridgeDiscovery.resolveUDID(
                        reported: status.udid,
                        recorded: BridgeDeviceRecord.load(port: port, repoRoot: self.repoRoot),
                        matchedByName: booted.count == 1 ? booted[0].udid : nil)
                    return (port, RunningBridge(udid: udid, name: status.device,
                                                engine: status.engine ?? "xcuitest",
                                                protocolVersion: status.protocolVersion,
                                                sessionBundleID: status.sessionBundleID,
                                                sourceDigest: InAppBridgeState.sourceDigest(
                                                    stateDir: self.repoRoot
                                                        .appendingPathComponent(".fleetest"),
                                                    port: port)))
                }
            }
            var result: [UInt16: RunningBridge] = [:]
            for await entry in group {
                if let (port, rb) = entry { result[port] = rb }
            }
            return result
        }
    }

    /// 空きポートの採番: spec.port 指定があればそれ(使用中なら次へ)、なければ範囲の先頭から
    /// 2パスで探す(.pid のあるポートはどちらのパスでも常に除外)。
    /// ignoringPidFileFor: このポートだけ pid ファイルが残っていても空き扱いにする
    /// (停止予定の旧版 xcuitest ブリッジの「同ポート再起動」用。停止はプランニング後の
    /// 並列実行フェーズで行われるため、プランニング時点では pid ファイルがまだ残っている)
    func assignPort(preferred: UInt16?, used: inout Set<UInt16>,
                    ignoringPidFileFor: UInt16? = nil) throws -> UInt16 {
        func isPidFree(_ port: UInt16) -> Bool {
            port == ignoringPidFileFor
                || !FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent(".fleetest/bridge-\(port).pid").path)
        }
        func hasInApp(_ port: UInt16) -> Bool {
            FileManager.default.fileExists(atPath: InAppBridgeState.url(
                stateDir: repoRoot.appendingPathComponent(".fleetest"), port: port).path)
        }
        // preferred も pid ファイル(=別ブリッジ稼働/stale)があれば honor しない(自動採番と同じ空き判定)。
        // .inapp のみは 2nd パス同様に許可(呼び出し元 planBridge が reclaimInApp で回収する)。
        if let preferred, !used.contains(preferred), isPidFree(preferred) {
            used.insert(preferred)
            return preferred
        }
        // 1st パス: .pid も .inapp も無いポートを優先
        for port in portRange where !used.contains(port) && isPidFree(port) && !hasInApp(port) {
            used.insert(port)
            return port
        }
        // 2nd パス: .inapp のみ残るポートを許可(呼び出し元 planBridge が起動前に回収する)。
        // 「.inapp の存在=予約」にはしない: ウェッジした in-app ブリッジが採番範囲全部に
        // 残ることが実際にあり、予約扱いだと即 noFreePort で枯渇するため後回しにするだけに留める
        for port in portRange where !used.contains(port) && isPidFree(port) {
            used.insert(port)
            return port
        }
        throw BridgeProvisionerError.noFreePort(scanned: portRange)
    }
}
