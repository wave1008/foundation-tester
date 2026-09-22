// MCPServer+BridgeRecovery.swift
// MCP が長く駆動する xcuitest ブリッジ(シミュレータ)の死亡からの自動復帰と、劣化の測り直し。
// 本体は MCPServer.swift。
//
// 実地(2026-09-22 B1): 3時間生きたランナーが a11y 照会の劣化の末に自壊し(ポートに何も応答しなくなり
// 台帳も消える)、以後そのセッションは connectionLostHint の案内(`fleetest bridge up` を打て)を
// 返すだけで、誰も打たないので二度と戻らなかった。ライブ操作(LiveBridgeAutoStarter)は同じ事象を
// 自動起動で凌ぐので、MCP にも同じ復帰を持たせる。**建て直しは BridgeProvisioner.provision の1箇所**
// (`fleetest bridge up` / run の供給と同じ経路。二つ目の実装を書かない)。
//
// **対象はシミュレータの xcuitest エンジンだけ**(RunnerMidRunRecheck.target と同じ絞り込み):
// hybrid/in-app は建て直しの単位が違う(対象アプリごと落ちる)・実機は provision() の対象外。
// それ以外の接続は従来どおり connectionLostHint の案内だけに落ちる(退化ではない——今までどおり)。

import Foundation
import FTBridgeClient
import FTCore

extension MCPServer {

    /// dispatch の薄いラッパー。`DriverError.bridgeConnectionRefused` を受け、建て直せる条件が
    /// 揃っていれば1回だけブリッジを建て直して撃ち直す。建て直せなければ元のエラーをそのまま
    /// 投げ、呼び出し元(call の catch)の connectionLostHint 等へ委ねる——文言・記憶の後始末を
    /// ここで重複して持たない
    /// 建て直したことを**結果本文の先頭に載せる**(既存の注記と同じ前置の形)。
    /// stderr だけに出すと **JSON-RPC しか読まない呼び手には届かない** ——
    /// 2026-09-21 T1 の「唯一の警告が stderr」と同じ型。この呼び出しが数分かかった理由も、
    /// 「同じポートで別のランナーに変わった」ことも、ここにしか現れない
    static let bridgeRebuiltNote =
        "⚠️ the xcuitest bridge on this device had died (nothing was listening) and was rebuilt"
        + " before this call ran. The app was relaunched, so the screen is back at its start"
        + " and every ref from an earlier ft_snapshot is gone — take a fresh one."

    func dispatchRetryingAfterBridgeRecovery(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        do {
            return try await dispatch(tool: tool, args: args)
        } catch {
            guard await attemptXCUITestBridgeRecovery(args: args, error: error) else { throw error }
            let content = try await dispatch(tool: tool, args: args)
            return [["type": "text", "text": Self.bridgeRebuiltNote]] + content
        }
    }

    /// **純粋関数**: xcuitest ブリッジの自動建て直しを試すかの判定材料を1箇所にまとめる
    /// (I/O 抜きでテストできる。attemptXCUITestBridgeRecovery が I/O 込みで呼ぶ)。
    /// このセッションで一度失敗した engineKey は再挑戦しない(`bridgeRecoveryFailed`。1回のビルド
    /// 失敗に分単位を払う経路なので、環境そのものが壊れている台へ毎呼び出し撃ち続けない ——
    /// LiveBridgeAutoStarter.maxConsecutiveFailures と同じ「無限リトライにしない」規律だが、
    /// MCP は1呼び出しで完結するので上限は1回で足りる)。実機は provision() の対象外
    static func shouldAttemptXCUITestBridgeRecovery(
        isConnectionRefused: Bool, engine: String?, alreadyFailedThisSession: Bool, isPhysical: Bool?
    ) -> Bool {
        guard isConnectionRefused, engine == "xcuitest", !alreadyFailedThisSession else { return false }
        return isPhysical == false
    }

    /// 建て直しの実行。判定は `shouldAttemptXCUITestBridgeRecovery` の1箇所(重複条件を書かない)。
    /// 成功時は `bridgeRecoveryFailed` へ insert しない——同じ台が後で再び死んだら、そのときはまた試してよい
    func attemptXCUITestBridgeRecovery(args: [String: Any], error: Error) async -> Bool {
        guard makeDriver == nil else { return false }
        let isConnectionRefused: Bool
        if case DriverError.bridgeConnectionRefused = error { isConnectionRefused = true }
        else { isConnectionRefused = false }
        let key = Self.engineKey(args)
        guard let port = connectedPorts[key], let udid = udids[key] ?? nil else { return false }
        guard Self.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: isConnectionRefused, engine: engines[key],
            alreadyFailedThisSession: bridgeRecoveryFailed.contains(key),
            isPhysical: SimulatorCatalog.isPhysical(udid: udid))
        else { return false }
        guard let repoRoot = try? RepoRoot.find() else { return false }
        Self.logStderr("bridge recovery: port \(port) refused the connection — rebuilding the"
            + " xcuitest bridge for \(udid) and retrying the call once")
        let spec = DeviceSpec(name: udid, udid: udid, port: port, engine: "xcuitest")
        do {
            _ = try await BridgeProvisioner(repoRoot: repoRoot)
                .provision(devices: [(udid, spec)], log: Self.logStderr)
            Self.logStderr("bridge recovery: rebuilt the xcuitest bridge on port \(port) for \(udid)")
            return true
        } catch {
            bridgeRecoveryFailed.insert(key)
            Self.logStderr("bridge recovery: could not rebuild the xcuitest bridge on port \(port)"
                + " for \(udid) (\(error.localizedDescription)) — not retried again this session")
            return false
        }
    }

    /// **純粋関数**: xcuitest ランナーの測り直しを撃つかの判定材料。閾値・材料の是非は
    /// `RunnerAccessibilityHealth.shouldRecheck` に委ね(新しい時間の定数を置かない)、
    /// ここで足すのはエンジン・実機の絞り込みだけ(RunnerMidRunRecheck.target と同じ絞り込み)
    static func shouldAttemptXCUITestRunnerRecheck(
        engine: String?, isPhysical: Bool?, maxStepSnapshotMs: Int?, injected: Bool
    ) -> Bool {
        guard engine == "xcuitest", isPhysical == false else { return false }
        return RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: maxStepSnapshotMs, injected: injected)
    }

    /// 呼び出し1回の所要が劣化の閾値を跨いだときだけ、その台のランナーを1問測り直して劣化していれば
    /// 建て直す(`RunnerAccessibilityHealth.probe`/`BridgeProvisioner.recheckRunner`。run 側の
    /// `RunnerMidRunRecheck` と同じ材料・同じ閾値を共有する)。建て直しても直らなかった台を覚えて
    /// 空振りを繰り返さないのは `RunnerRestartFutility`(プロセス共有の帳簿。recheckRunner の内側で
    /// 参照する——ここでは何も持たない)
    func recheckXCUITestRunnerIfSlow(args: [String: Any], elapsedMs: Int) async {
        guard makeDriver == nil else { return }
        let key = Self.engineKey(args)
        guard let port = connectedPorts[key], let udid = udids[key] ?? nil else { return }
        let injected = RunnerAccessibilityHealth.injectedSlowPorts().contains(port)
        // **`SimulatorCatalog.isPhysical` は shouldRecheck が通ってから引く**: これはほぼ全ての
        // 成功呼び出しの後に走るので、遅かった回(稀)だけに絞ってから simctl/devicectl を撃つ
        // (先に引くと健全な呼び出しのたびに一覧照会を払うことになる)
        guard RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: elapsedMs, injected: injected),
              Self.shouldAttemptXCUITestRunnerRecheck(
                  engine: engines[key], isPhysical: SimulatorCatalog.isPhysical(udid: udid),
                  maxStepSnapshotMs: elapsedMs, injected: injected)
        else { return }
        guard let repoRoot = try? RepoRoot.find() else { return }
        let result = await BridgeProvisioner(repoRoot: repoRoot).recheckRunner(
            name: udid, udid: udid, port: port, injected: injected, log: Self.logStderr)
        switch result.outcome {
        case .healthy, .unmeasured:
            Self.logStderr(RunnerAccessibilityHealth.leftRunningMessage(
                name: udid, port: port, maxStepSnapshotMs: elapsedMs, probeSeconds: result.probeSeconds))
        case .restarted(let afterSeconds):
            let now = afterSeconds.map { "; a one-element query now takes \(String(format: "%.2f", $0))s" } ?? ""
            Self.logStderr("✅ \(udid): restarted the xcuitest bridge on port \(port)\(now)")
        case .restartDidNotHelp, .skipped:
            break  // restartRunner/recheckRunner が既に1行出し済み
        case .restartFailed(let reason):
            Self.logStderr("⚠️ \(udid): could not restart the xcuitest bridge on port \(port) (\(reason))")
        }
    }
}
