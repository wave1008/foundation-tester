// live / MCP(ft_* ツール)専用のブリッジ振り替え。
//
// live/MCP は **in-app エンジンを使わない**(ユーザー決定 2026-07-28)。in-app ブリッジは
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
    ///   - logger: 振り替え・起動の進捗(呼び出し側の stderr 等へ)
    public static func resolve(preferred: UInt16, repoRoot: URL?, autoStart: Bool = true,
                               logger: @Sendable (String) -> Void = { _ in }) async -> Resolution {
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
            let note = "port \(preferred) は in-app ブリッジのため XCUITest ブリッジ(port \(found.port))へ振り替えました"
            logger(note)
            return Resolution(endpoint: found, note: note)
        }
        guard autoStart else {
            let note = "port \(preferred) は in-app ブリッジです"
                + "(このデバイスの XCUITest ブリッジが見つかりません。`ftester bridge up` で用意してください)"
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
        BridgeClient(port: endpoint.port, timeoutSeconds: timeout, host: endpoint.host)
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
                              logger: @Sendable (String) -> Void) async -> Resolution {
        func giveUp(_ reason: String) -> Resolution {
            logger(reason)
            return Resolution(endpoint: fallback, note: reason)
        }
        guard let repoRoot else {
            return giveUp("XCUITest ブリッジを起動できません(リポジトリルートが未解決)")
        }
        let booted = ((try? SimulatorCatalog.devices()) ?? []).filter { $0.booted && $0.name == device }
        guard booted.count == 1 else {
            return giveUp("XCUITest ブリッジを起動できません"
                + "(デバイス「\(device)」を一意に特定できません: 起動中 \(booted.count) 台)")
        }
        guard let port = freePort(repoRoot: repoRoot, occupied: occupied) else {
            return giveUp("XCUITest ブリッジを起動できません(空きポートがありません)")
        }
        logger("in-app ブリッジしか居ないため XCUITest ブリッジを起動します"
            + "(port \(port), \(device)。初回は build-for-testing で数分かかります)")
        let launcher = BridgeLauncher(repoRoot: repoRoot, device: booted[0].udid, port: port,
                                      physical: booted[0].physical)
        do {
            try launcher.generateProjectIfNeeded()
            do {
                try launcher.startDetached()
            } catch LauncherError.xctestrunNotFound {
                try launcher.buildForTesting()
                try launcher.startDetached()
            }
            try await launcher.waitUntilReady()
        } catch {
            // 起動途中のプロセス・pid ファイルを残さない(以後のポート採番を汚すため。
            // LiveBridgeAutoStarter.launchBridge と同じ後始末)
            try? launcher.stop()
            return giveUp("XCUITest ブリッジの起動に失敗しました: \(error.localizedDescription)")
        }
        let note = "XCUITest ブリッジを起動しました(port \(port))"
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
                    atPath: repoRoot.appendingPathComponent(".ftester/bridge-\(port).pid").path)
        }
    }
}
