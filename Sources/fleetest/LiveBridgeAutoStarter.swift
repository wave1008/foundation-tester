// api live serve 専用: XCUITest ブリッジ接続拒否(DriverError.bridgeConnectionRefused)を
// 検知したら自動起動する状態機械。加えて、旧ビルドのブリッジ(/status の protocolVersion が
// 現行値と不一致)を検知したら再起動する。ApiLiveCommand.swift から使う。
//
// 状態: idle → (noteConnectionRefused) → starting → 成功で idle(カウンタもリセット) /
// 失敗で idle に戻り再トリガー可、ただし連続 maxConsecutiveFailures 回失敗したら failed(恒久、
// 以後 noteConnectionRefused を呼んでも起動しない。xcodebuild の無限リトライ防止)。
//
// 罠: generateProjectIfNeeded/buildForTesting/startDetached は Shell.run の同期ブロッキングで
// 数分かかりうる。actor メソッド内で直接実行すると、これを await する serve のコマンドループ
// 全体が固まる。そのため起動処理は launchBridge(nonisolated static)を Task.detached で
// actor の外で実行し、完了後だけ actor のメソッド(finishLaunch)で状態を更新する。

import FTBridgeClient
import FTCore
import Foundation

actor LiveBridgeAutoStarter {
    private enum State {
        case idle
        case starting
        case failed(String)
    }

    private static let maxConsecutiveFailures = 2

    private let repoRoot: URL
    private let udid: String
    private let port: UInt16
    /// 実機かシミュレータか(BridgeLauncher.physical に渡す。UDID の形状では判別できないため
    /// 呼び出し側が構築時に一度だけ確定させる。SimulatorCatalog.isPhysical(udid:) 参照)
    private let physical: Bool
    /// USB 接続か(devicectl の transportType == "wired")。実機の到達手段の選択に使う
    /// (USB = iproxy トンネル / LAN = ランナーが告知するアドレス)。シミュレータでは読まない
    private let wired: Bool
    private var state: State = .idle
    private var consecutiveFailures = 0
    /// 直近の自動起動が成功してから、まだ呼び手が宛先を引き直していないか(takeStarted で消費)
    private var startedSinceLastCheck = false

    init(repoRoot: URL, udid: String, port: UInt16, physical: Bool, wired: Bool) {
        self.repoRoot = repoRoot
        self.udid = udid
        self.port = port
        self.physical = physical
        self.wired = wired
    }

    /// 接続拒否を観測したとき呼ぶ。idle なら起動タスクを開始する(starting/failed 中は何もしない
    /// = xcodebuild の二重起動を防ぐ)。戻り値は更新後の状態サフィックス
    func noteConnectionRefused() -> String {
        if case .idle = state {
            state = .starting
            logStderr("Connection refused — auto-starting the bridge (udid: \(udid), port: \(port))")
            let repoRoot = self.repoRoot
            let udid = self.udid
            let port = self.port
            let physical = self.physical
            let wired = self.wired
            Task.detached { [weak self] in
                let result = await Self.launchBridge(
                    repoRoot: repoRoot, udid: udid, port: port, physical: physical, wired: wired)
                await self?.finishLaunch(result: result)
            }
        }
        return suffix()
    }

    /// 状態サフィックスのみ返す(起動はトリガーしない)
    func statusSuffix() -> String {
        suffix()
    }

    /// serve 起動時に呼ぶ。旧ビルドのブリッジ(/status の protocolVersion が現行値と不一致)を
    /// 検知したら再起動する。接続不可(不在含む)は何もしない(不在は既存の接続拒否経路が担当)
    func checkAndRestartIfStale() async {
        // LAN・usb 経由の実機は 127.0.0.1 に居ない(usb は host こそループバックだが token が要る)。
        // establish が残した宛先(host・token)をそのまま問う(記録が無ければループバック・token 無し)
        let client = BridgeClient(endpoint: BridgeEndpoint.load(port: port, repoRoot: repoRoot),
                                  timeoutSeconds: 3)
        guard let status = try? await client.status() else { return }
        if status.ready && status.protocolVersion == BridgeAPI.bridgeProtocolVersion { return }
        guard case .idle = state else { return }
        state = .starting
        let actual = status.protocolVersion.map(String.init) ?? "none"
        logStderr("Detected a bridge from an older build (port \(port)) — restarting it" +
            "(version: \(actual) → \(BridgeAPI.bridgeProtocolVersion))")
        let repoRoot = self.repoRoot
        let udid = self.udid
        let port = self.port
        let physical = self.physical
        let wired = self.wired
        Task.detached { [weak self] in
            let result = await Self.launchBridge(
                repoRoot: repoRoot, udid: udid, port: port, physical: physical, wired: wired,
                stopFirst: true)
            await self?.finishLaunch(result: result)
        }
    }

    private func suffix() -> String {
        switch state {
        case .idle:
            return ""
        case .starting:
            return "(Auto-starting the XCUITest bridge. The first build takes several minutes. " +
                "This screen recovers automatically once it is ready.)"
        case .failed(let detail):
            return "(Bridge auto-start failed: \(detail). " +
                "Run `fleetest bridge up --device \(udid) --port \(port)`.)"
        }
    }

    /// 自動起動が成功した直後の1回だけ true。**実機の LAN では宛先が変わる**(起動前は loopback、
    /// 起動後はランナーが告知した LAN アドレスを `.endpoint` に残す)ので、呼び手はこれを見て
    /// BridgeEndpoint.load で張り直す。張り直さないと loopback へ撃ち続けて接続拒否 → 再起動の
    /// 無限ループになる(2026-09-07 iPhone 13/LAN で実測: 起動は成功するのに毎回「leftover」として
    /// 自分で止めていた)
    func takeStarted() -> Bool {
        defer { startedSinceLastCheck = false }
        return startedSinceLastCheck
    }

    private func finishLaunch(result: Result<Void, Error>) {
        switch result {
        case .success:
            state = .idle
            consecutiveFailures = 0
            startedSinceLastCheck = true
            logStderr("Bridge auto-start succeeded (udid: \(udid), port: \(port))")
        case .failure(let error):
            consecutiveFailures += 1
            let detail = error.localizedDescription
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                state = .failed(detail)
                logStderr("Bridge auto-start failed \(consecutiveFailures) times in a row — giving up: " +
                    "\(detail)")
            } else {
                state = .idle  // 次の noteConnectionRefused で再試行を許可する
                logStderr("Bridge auto-start failed (attempt \(consecutiveFailures), will retry): \(detail)")
            }
        }
    }

    /// actor の外で実行する起動処理本体。失敗時は起動途中のプロセス・pid ファイルを後始末する
    /// (BridgeProvisioner.provision と同じ理由: 残すと以後のポート採番を汚す)。
    /// **起動(pid ファイルが書かれるまで)は ProvisionLock で直列化する** ——
    /// port は呼び出し元(実行プロファイル)が固定するため自前の採番は無いが、まだ pid ファイルが
    /// 無い間に BridgeProvisioner.provision() が同じポートを空きと採番する競合があり得るため
    private static func launchBridge(
        repoRoot: URL, udid: String, port: UInt16, physical: Bool, wired: Bool, stopFirst: Bool = false
    ) async -> Result<Void, Error> {
        let launcher = BridgeLauncher(repoRoot: repoRoot, device: udid, port: port, physical: physical)
        let provisionLock = try? ProvisionLock(stateDir: repoRoot.appendingPathComponent(".fleetest"))
        await provisionLock?.acquire()
        var lockReleased = false
        func releaseLockOnce() {
            guard !lockReleased else { return }
            lockReleased = true
            provisionLock?.release()
        }
        do {
            if stopFirst {
                do {
                    try await launcher.stopAndWait()
                } catch LauncherError.notRunning {
                    // pid ファイル無し = このリポジトリ管理外のプロセスがポートを握っている。
                    // ここで startDetached に進むとポート衝突で旧 /status を拾い偽成功になる
                    releaseLockOnce()
                    return .failure(AutoStarterError.staleStopFailed(port: port))
                }
            }
            // このポートは実行プロファイルが固定するため freePort のような採番替えは無い。
            // それでも「今 LISTEN している実体」は確かめる —— 背面へ回った in-app ブリッジは
            // .pid を持たず /status にも答えないため、確認しないまま startDetached すると
            // bindFailed(48) で気づく(BridgeProvisioner.executeBridge と同じ判定を再利用する。
            // 二つ目の実装を書かない)
            let stateDir = repoRoot.appendingPathComponent(".fleetest")
            switch PortHolder.stopIfOwnedBridge(
                port: port, stateDir: stateDir,
                derivedDataPath: stateDir.appendingPathComponent("DerivedData")) {
            case .stopped:
                break
            case .notFound:
                break
            case .foreign(let holder):
                // ポートは固定なので次のポートへは逃がせない。占有者を名指しして諦める
                // (原因不明の bindFailed 待ちより先に理由を返す)
                releaseLockOnce()
                return .failure(AutoStarterError.portHeldByForeignProcess(port: port, holder: holder))
            }
            try launcher.generateProjectIfNeeded()
            try launcher.rebuildIfStale()
            do {
                try launcher.startDetached()
            } catch LauncherError.xctestrunNotFound {
                try launcher.buildForTesting()
                try launcher.startDetached()
            }
            // ポート確保(pid ファイル書き込み)完了。ready 待ちはロックの外へ
            releaseLockOnce()
            // 実機はデバイス内ループバックにホストから届かない。establish で到達手段
            // (LAN の宛先解決 or iproxy の USB トンネル)を確立してから待つ
            // (BridgeProvisioner.executeBridge と同じ手順。飛ばすとループバックを待ち続け、
            // 実機のライブ復帰が必ず 180 秒後に failed になる)
            var establishedEndpoint: BridgeEndpoint?
            if physical {
                do {
                    establishedEndpoint = try await IOSDeviceTransport.establish(
                        port: port, deviceUDID: udid, repoRoot: repoRoot, wired: wired,
                        token: launcher.bridgeToken,
                        log: { message in
                            ConsoleOut.err("[live serve] \(message)")
                        })
                } catch {
                    // launcher.stop() が establish の到達手段(iproxy/endpoint 記録)の
                    // teardown も内包する(IOSDeviceTransport.teardown を直接呼ぶのと同じ)
                    try? launcher.stop()
                    return .failure(error)
                }
            }
            try await launcher.waitUntilReady(endpoint: establishedEndpoint)
            return .success(())
        } catch {
            releaseLockOnce()
            try? launcher.stop()
            return .failure(error)
        }
    }

    private func logStderr(_ message: String) {
        ConsoleOut.err("[live serve] " + message)
    }
}

private enum AutoStarterError: Error, LocalizedError {
    case staleStopFailed(port: UInt16)
    /// port は実行プロファイルが固定するため、freePort のような採番替えができない
    /// (XCUIBridgeResolver.start と違い、次の空きポートへは逃がせない)
    case portHeldByForeignProcess(port: UInt16, holder: String)

    var errorDescription: String? {
        switch self {
        case .staleStopFailed(let port):
            return "cannot stop the stale bridge (no pid file). " +
                "Run `fleetest bridge down --port \(port)`"
        case .portHeldByForeignProcess(let port, let holder):
            return "port \(port) is held by an unrelated process (\(holder)). " +
                "Run `fleetest bridge down --port \(port)` or stop it manually"
        }
    }
}
