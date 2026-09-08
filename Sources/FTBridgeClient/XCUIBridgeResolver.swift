// live / MCP(ft_* ツール)専用のブリッジ振り替え。
//
// live/MCP は **in-app エンジンを使わない**(ユーザー決定)。in-app ブリッジは
// home / appSwitcher / drag / 座標 press を原理的に実装できず、シナリオ実行と違って
// StepExecutor のフォールバック機構を通らないため、これらが素の 501 で落ちる。
// そこで接続先が in-app だと分かったら、同じデバイスの XCUITest ブリッジへ振り替える
// (無ければ空きポートに起動する)。
//
// 呼び出し側の契約: 起動を伴う経路は分単位でブロックし得る(初回は build-for-testing)。
// 進捗は logger で呼び出し側の stderr へ出すこと。

import FTCore
import Foundation

public enum XCUIBridgeResolver {
    public struct Resolution: Sendable {
        public let endpoint: BridgeEndpoint
        /// 振り替え・起動が起きたとき、または振り替えられなかった理由。nil = 指定ポートのまま
        public let note: String?
    }

    static let portRange: ClosedRange<UInt16> = BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31)

    /// 指定ポートが in-app ブリッジなら XCUITest ブリッジの宛先を返す。それ以外(応答なし・
    /// xcuitest・Android)は指定ポートをそのまま返す = 既存挙動のまま。
    /// - Parameters:
    ///   - autoStart: 既存の XCUITest ブリッジが見つからないとき起動するか
    ///   - logsReroute: 「振り替えた」と告げるか。**false = 呼び出し側が別の使い方をする**
    ///     (ExploreDriverResolver は返ってきた宛先をフォールバックに使うだけで振り替えない。
    ///     そのまま出すと自分の説明と矛盾する)。起動の進捗は false でも出す(分単位ブロックし得る)
    public static func resolve(preferred: UInt16, repoRoot: URL?, autoStart: Bool = true,
                               logsReroute: Bool = true,
                               logger: @escaping @Sendable (String) -> Void = { _ in }) async -> Resolution {
        let preferredEndpoint = endpoint(port: preferred, repoRoot: repoRoot)
        // status(timeout:) を明示する(引数なしは sessionTimeout=45s に上書きされ、
        // 無応答の孤児ブリッジ1本で待たされる。BridgeProvisioner.scanRunningBridges と同じ理由)
        guard let status = try? await client(preferredEndpoint, timeout: 3).status(timeout: 3),
              status.engine == "inapp" else {
            return Resolution(endpoint: preferredEndpoint, note: nil)
        }
        let device = status.device
        let scan = await scanBridges(device: device, excluding: preferred, repoRoot: repoRoot)

        if let found = scan.xcuiForDevice {
            let note = "port \(preferred) is an in-app bridge — rerouted to the XCUITest bridge (port \(found.port))"
            if logsReroute { logger(note) }
            return Resolution(endpoint: found, note: note)
        }
        guard autoStart else {
            let note = "port \(preferred) is an in-app bridge"
                + " (no XCUITest bridge found for this device; provide one with `fleetest bridge up`)"
            logger(note)
            return Resolution(endpoint: preferredEndpoint, note: note)
        }
        return await start(forDevice: device, repoRoot: repoRoot, occupied: scan.live.union([preferred]),
                           fallback: preferredEndpoint, logger: logger)
    }

    // MARK: - 内部

    private static func endpoint(port: UInt16, repoRoot: URL?) -> BridgeEndpoint {
        // 実機ブリッジは 127.0.0.1 に居ない。provision が残した宛先を使う
        repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) } ?? BridgeEndpoint(port: port)
    }

    private static func client(_ endpoint: BridgeEndpoint, timeout: TimeInterval) -> BridgeClient {
        BridgeClient(endpoint: endpoint, timeoutSeconds: timeout)
    }

    private struct Scan {
        /// 同じデバイスの XCUITest ブリッジ(あれば最小ポート)
        let xcuiForDevice: BridgeEndpoint?
        /// 応答があったポート全部。**起動時のポート採番に必要**: in-app ブリッジは pid ファイルを
        /// 持たない(dylib 注入)ので、pid ファイルだけ見ると稼働中ポートを空きと誤判定する
        let live: Set<UInt16>
    }

    /// 稼働中ブリッジを1回だけ走査する。デバイス名で相関するのは /status がデバイス名しか
    /// 返さないため(BridgeProvisioner.scanRunningBridges と同じ制約)
    private static func scanBridges(device: String, excluding: UInt16, repoRoot: URL?) async -> Scan {
        let found = await withTaskGroup(of: (UInt16, Bool)?.self) { group in
            for port in portRange where port != excluding {
                group.addTask {
                    let endpoint = endpoint(port: port, repoRoot: repoRoot)
                    guard let status = try? await client(endpoint, timeout: 2).status(timeout: 2),
                          status.ready else { return nil }
                    let usable = status.device == device && (status.engine ?? "xcuitest") != "inapp"
                    return (port, usable)
                }
            }
            var result: [(UInt16, Bool)] = []
            for await entry in group { if let entry { result.append(entry) } }
            return result
        }
        // 最小ポートに寄せる(どれでも正しいが、run ごとに宛先が揺れると診断しづらい)
        let usable = found.filter(\.1).map(\.0).min()
        return Scan(xcuiForDevice: usable.map { endpoint(port: $0, repoRoot: repoRoot) },
                    live: Set(found.map(\.0)))
    }

    /// 空きポートに XCUITest ブリッジを起動する。udid はデバイス名から引く(同名が複数
    /// 起動中なら特定できないので起動しない = 誤ったデバイスを掴むより指定ポートのまま返す)
    private static func start(forDevice device: String, repoRoot: URL?, occupied: Set<UInt16>,
                              fallback: BridgeEndpoint,
                              logger: @escaping @Sendable (String) -> Void) async -> Resolution {
        func giveUp(_ reason: String) -> Resolution {
            logger(reason)
            return Resolution(endpoint: fallback, note: reason)
        }
        guard let repoRoot else {
            return giveUp("cannot start the XCUITest bridge (repository root unresolved)")
        }
        let booted = ((try? SimulatorCatalog.devices()) ?? []).filter { $0.booted && $0.name == device }
        guard booted.count == 1 else {
            return giveUp("cannot start the XCUITest bridge"
                + " (device \"\(device)\" is ambiguous: \(booted.count) booted)")
        }
        // 空きポート選択 → 起動(pid ファイルが書かれるまで)は provision() と同じ
        // ProvisionLock で直列化する。取れなければ(他プロセスが未解放等)ロック無しで
        // 進む = 既存挙動のまま(採番衝突より起動できないことのほうが害が大きい)
        let provisionLock = try? ProvisionLock(stateDir: repoRoot.appendingPathComponent(".fleetest"))
        await provisionLock?.acquire()
        var lockReleased = false
        func releaseLockOnce() {
            guard !lockReleased else { return }
            lockReleased = true
            provisionLock?.release()
        }
        defer { releaseLockOnce() }

        // freePort は .pid ファイルと稼働中(応答あり)ポートしか見ない。**背面へ回った
        // in-app ブリッジ**(TCP は受け付けるが HTTP に答えない・.pid も持たない・
        // scanBridges の応答走査にも live 一覧にも映らない)は空きに見えるため、そのまま
        // startDetached すると bindFailed(48) → giveUp になる。実際に LISTEN している実体を
        // PortHolder で確かめてから使う(BridgeProvisioner.executeBridge と同じ判定・
        // 二つ目の実装を書かず PortHolder/StaleBridgeStop を再利用する)
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        var occupied = occupied
        var foreignHolders: [String] = []
        var port: UInt16?
        while port == nil {
            guard let candidate = freePort(repoRoot: repoRoot, occupied: occupied) else {
                let detail = foreignHolders.isEmpty ? "" : " (held by \(foreignHolders.joined(separator: ", ")))"
                return giveUp("cannot start the XCUITest bridge (no free port\(detail))")
            }
            switch PortHolder.stopIfOwnedBridge(
                port: candidate, stateDir: stateDir,
                derivedDataPath: stateDir.appendingPathComponent("DerivedData")) {
            case .stopped(let holder):
                logger("port \(candidate) was held by a leftover bridge (\(holder)) — stopped it")
                port = candidate
            case .notFound:
                port = candidate
            case .foreign(let holder):
                // 無関係プロセスの占有は撃たない —— 次の空きポートを試す(占有者を名指しした
                // まま黙って諦めず、全滅したら giveUp で理由を出す。「起動を試みて bindFailed で
                // 気づく」という無情報な失敗にしない)
                logger("port \(candidate) is held by an unrelated process (\(holder)) — trying the next port")
                foreignHolders.append("port \(candidate): \(holder)")
                occupied.insert(candidate)
            }
        }
        guard let port else {
            return giveUp("cannot start the XCUITest bridge (no free port)")
        }
        logger("Only an in-app bridge is present — starting an XCUITest bridge"
            + " (port \(port), \(device); the first build-for-testing takes several minutes)")
        let device0 = booted[0]
        let launcher = BridgeLauncher(repoRoot: repoRoot, device: device0.udid, port: port,
                                      physical: device0.physical)
        do {
            try launcher.generateProjectIfNeeded()
            try launcher.rebuildIfStale()
            do {
                try launcher.startDetached()
            } catch LauncherError.xctestrunNotFound {
                try launcher.buildForTesting()
                try launcher.startDetached()
            }
            // ポート確保(pid ファイル書き込み)はここで完了。ready 待ちはロックの外へ出す
            // (provision() の PortClaimBarrier と同じ理屈 —— 待つのは自分だけなので早期解放で足りる)
            releaseLockOnce()
            // 実機はデバイス内ループバックにホストから届かない。/status を叩く前に到達手段
            // (LAN の宛先解決 or iproxy の USB トンネル)を確立する(BridgeProvisioner.executeBridge
            // と同じ手順)。これを飛ばすと waitUntilReady がループバックへ待ち続け、
            // 実機では必ず 180 秒後に failed になる
            var establishedEndpoint: BridgeEndpoint?
            if device0.physical {
                do {
                    establishedEndpoint = try await IOSDeviceTransport.establish(
                        port: port, deviceUDID: device0.udid, repoRoot: repoRoot,
                        wired: device0.wired, token: launcher.bridgeToken, log: logger)
                } catch {
                    try? launcher.stop()
                    return giveUp("failed to start the XCUITest bridge: \(error.localizedDescription)")
                }
            }
            try await launcher.waitUntilReady(endpoint: establishedEndpoint, log: logger)
        } catch {
            releaseLockOnce()
            // 起動途中のプロセス・pid ファイルを残さない(以後のポート採番を汚すため。
            // LiveBridgeAutoStarter.launchBridge と同じ後始末。launcher.stop() が実機の
            // 到達手段(iproxy/endpoint 記録)の teardown も内包する)
            try? launcher.stop()
            return giveUp("failed to start the XCUITest bridge: \(error.localizedDescription)")
        }
        let note = "started the XCUITest bridge (port \(port))"
        logger(note)
        return Resolution(endpoint: BridgeEndpoint.load(port: port, repoRoot: repoRoot), note: note)
    }

    /// 空きポートを小さい順に。**pid ファイルと稼働中ポートの両方**で弾く:
    /// in-app ブリッジは pid ファイルを持たない(dylib 注入)ため、pid だけ見ると
    /// in-app が待受中のポートを空きと誤判定してポート衝突を起こす
    private static func freePort(repoRoot: URL, occupied: Set<UInt16>) -> UInt16? {
        portRange.first { port in
            !occupied.contains(port)
                && !FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent(".fleetest/bridge-\(port).pid").path)
        }
    }
}
