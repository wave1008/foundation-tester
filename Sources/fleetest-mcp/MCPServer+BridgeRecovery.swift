// MCPServer+BridgeRecovery.swift
// MCP が長く駆動する xcuitest ブリッジ(シミュレータ)の死亡からの自動復帰と、劣化の測り直し。
// 本体は MCPServer.swift。
//
// 実地(B1): 3時間生きたランナーが a11y 照会の劣化の末に自壊し(ポートに何も応答しなくなり
// 台帳も消える)、以後そのセッションは connectionLostHint の案内(`fleetest bridge up` を打て)を
// 返すだけで、誰も打たないので二度と戻らなかった。ライブ操作(LiveBridgeAutoStarter)は同じ事象を
// 自動起動で凌ぐので、MCP にも同じ復帰を持たせる。**起動し直しは BridgeProvisioner.provision の1箇所**
// (`fleetest bridge up` / run の供給と同じ経路。二つ目の実装を書かない)。
//
// **対象はシミュレータの xcuitest エンジンだけ**(RunnerMidRunRecheck.target と同じ絞り込み):
// hybrid/in-app は起動し直しの単位が違う(対象アプリごと落ちる)・実機は provision() の対象外。
// それ以外の接続は connectionLostHint の案内だけに落ちる(退化ではなく対象外なだけ)。
//
// **入口は 2 つ**: ①覚えたポートの接続拒否(`dispatchRetryingAfterBridgeRecovery`)②udid の畳み込みで「その Simulator に
// 何も待ち受けていない」(`rebuildMissingSimulatorBridge`。`portForIOS` から)。udid を毎回添える呼び手は①を踏まない
// (走査が先に「no running bridge」で落ちる)ので、②が無いとランナーが死んだ瞬間からそのセッションは二度と戻らない
// (10/18 の負荷テスト: ランナーを殺した後の 5 分で 300 回)。どちらも provision は BridgeProvisioner.provision の 1 箇所。

import Foundation
import FTBridgeClient
import FTCore

extension MCPServer {

    /// dispatch の薄いラッパー。`DriverError.bridgeConnectionRefused` を受け、起動し直せる条件が
    /// 揃っていれば1回だけブリッジを起動し直して撃ち直す。起動し直せなければ元のエラーをそのまま
    /// 投げ、呼び出し元(call の catch)の connectionLostHint 等へ委ねる——文言・記憶の後始末を
    /// ここで重複して持たない
    /// 起動し直したことを**結果本文の先頭に載せる**(既存の注記と同じ前置の形)。
    /// stderr だけに出すと **JSON-RPC しか読まない呼び手には届かない** ——
    /// T1 の「唯一の警告が stderr」と同じ型。この呼び出しが数分かかった理由も、
    /// 「同じポートで別のランナーに変わった」ことも、ここにしか現れない
    static let bridgeRebuiltNote =
        "⚠️ the xcuitest bridge on this device had died (nothing was listening) and was rebuilt"
        + " before this call ran. The app was relaunched, so the screen is back at its start"
        + " and every ref from an earlier ft_snapshot is gone — take a fresh one."

    /// 畳み込みの中でランナーを起動し直した呼び出しの応答(成功なら先頭・失敗ならエラー文の先頭)に載せる
    /// (`bridgeRebuiltNote` と同じ理由で本文に出す。起動し直した直後の ref 操作が失敗した回こそ ref の消失を言う必要がある)
    static let bridgeStartedForUDIDNote =
        "⚠️ no xcuitest bridge was running on this simulator (nothing listened for its udid), so one was started"
        + " before this call ran. The app was relaunched, so the screen is back at its start and every ref from an"
        + " earlier ft_snapshot is gone — take a fresh one."

    func dispatchRetryingAfterBridgeRecovery(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        do {
            return try await dispatch(tool: tool, args: args)
        } catch {
            guard await attemptXCUITestBridgeRecovery(args: args, error: error) else { throw error }
            let content = try await dispatch(tool: tool, args: args)
            return [["type": "text", "text": Self.bridgeRebuiltNote]] + content
        }
    }

    /// **純粋関数**: xcuitest ブリッジの自動での起動し直しを試すかの判定材料を1箇所にまとめる
    /// (I/O 抜きでテストできる。attemptXCUITestBridgeRecovery が I/O 込みで呼ぶ)。
    /// このセッションで一度失敗した engineKey は再挑戦しない(`bridgeRecoveryFailed`。1回のビルド
    /// 失敗に分単位を払う経路なので、環境そのものが壊れているデバイスへ毎呼び出し撃ち続けない ——
    /// LiveBridgeAutoStarter.maxConsecutiveFailures と同じ「無限リトライにしない」規律だが、
    /// MCP は1呼び出しで完結するので上限は1回で足りる)。実機は provision() の対象外。
    /// **他のセッション(run・別の MCP)が使っているデバイスには撃たない**(`heldByAnotherSession` =
    /// `RunnerAccessibilityHealth.hasForeignLease`)—— 起動し直すのはそのデバイスのランナーなので、
    /// run が引き取ったデバイスでは run のレーンを落とす。引数に既定値を置かない = 呼び手の渡し忘れを止める
    static func shouldAttemptXCUITestBridgeRecovery(
        isConnectionRefused: Bool, engine: String?, alreadyFailedThisSession: Bool, isPhysical: Bool?,
        heldByAnotherSession: Bool
    ) -> Bool {
        guard isConnectionRefused, engine == "xcuitest", !alreadyFailedThisSession,
              !heldByAnotherSession else { return false }
        return isPhysical == false
    }

    /// run-lease / 他の MCP セッションの印(自分と親の分は数えない)。判定は供給の門と同じ1箇所
    static func heldByAnotherSession(udid: String, repoRoot: URL) -> Bool {
        RunnerAccessibilityHealth.hasForeignLease(
            udid: udid, stateDir: repoRoot.appendingPathComponent(".fleetest"))
    }

    static func skippedForAnotherSessionMessage(action: String, udid: String, port: UInt16) -> String {
        "not \(action) the xcuitest bridge on port \(port) for \(udid): another session (a fleetest run"
            + " or another MCP session) is using this device — restarting its runner would break that session"
    }

    /// 起動し直しの実行。判定は `shouldAttemptXCUITestBridgeRecovery` の1箇所(重複条件を書かない)。
    /// 成功時は `bridgeRecoveryFailed` へ insert しない——同じデバイスが後で再び死んだら、そのときはまた試してよい
    func attemptXCUITestBridgeRecovery(args: [String: Any], error: Error) async -> Bool {
        guard makeDriver == nil else { return false }
        let isConnectionRefused: Bool
        if case DriverError.bridgeConnectionRefused = error { isConnectionRefused = true }
        else { isConnectionRefused = false }
        let key = Self.engineKey(args)
        guard let port = connectedPorts[key], let udid = udids[key] ?? nil,
              let repoRoot = try? RepoRoot.find() else { return false }
        let heldByAnotherSession = Self.heldByAnotherSession(udid: udid, repoRoot: repoRoot)
        guard Self.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: isConnectionRefused, engine: engines[key],
            alreadyFailedThisSession: bridgeRecoveryFailed.contains(key),
            isPhysical: SimulatorCatalog.isPhysical(udid: udid), heldByAnotherSession: heldByAnotherSession)
        else {
            if isConnectionRefused, heldByAnotherSession {
                Self.logStderr("bridge recovery: " + Self.skippedForAnotherSessionMessage(
                    action: "rebuilding", udid: udid, port: port))
            }
            return false
        }
        SlowCallWatchdog.mark("rebuilding the xcuitest bridge on port \(port)")
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

    /// **純粋関数**: udid の畳み込みで「Simulator に何も待ち受けていない」とき、そのランナーを起動し直すかの判定材料
    /// (`shouldAttemptXCUITestBridgeRecovery` と同じ門: このセッションで一度失敗したら再挑戦しない・他のセッションの端末には撃たない。
    /// 実機は `portForIOS` が `.physical` へ分けるのでここへ来ない)。`lookup` が Simulator と言い切れ、診断が完走して何も
    /// 待ち受けていないときだけ。busy・固まり・答えたが確かめられない・予算切れ・一覧が読めないは「居ない」ではない
    static func shouldRebuildMissingSimulatorBridge(
        lookup: SimulatorCatalog.UDIDLookup, nothingListens: Bool, alreadyFailedThisSession: Bool,
        heldByAnotherSession: Bool
    ) -> Bool {
        guard nothingListens, lookup == .simulator, !alreadyFailedThisSession, !heldByAnotherSession else { return false }
        return true
    }

    /// 畳み込み(`portForIOS`)から。その udid の xcuitest ランナーを起動し直し、ポートを返す(起動し直さない・できないは nil)。
    /// `sessionKey` は畳む前の engineKey(port 無し)= 失敗の記憶を置く DeviceSession の鍵(中身は udid ごと)。
    /// 起動し直したことの注記は呼び手(call)がその呼び出しの中だけで持つ(成功・失敗のどちらの応答にも載せる・次の呼び出しへ持ち越さない)
    func rebuildMissingSimulatorBridge(udid: String, diagnosis: UDIDBridgeDiagnosis, sessionKey: String) async -> UInt16? {
        guard makeDriver == nil, let repoRoot = try? RepoRoot.find() else { return nil }
        let heldByAnotherSession = Self.heldByAnotherSession(udid: udid, repoRoot: repoRoot)
        guard Self.shouldRebuildMissingSimulatorBridge(
            lookup: diagnosis.lookup, nothingListens: Self.nothingListensFor(diagnosis),
            alreadyFailedThisSession: sessions[sessionKey]?.simulatorBridgeRebuildFailedUDIDs.contains(udid) ?? false,
            heldByAnotherSession: heldByAnotherSession)
        else {
            if heldByAnotherSession {
                Self.logStderr("bridge recovery: not starting an xcuitest bridge for \(udid): another session (a fleetest run"
                    + " or another MCP session) is using this device")
            }
            return nil
        }
        SlowCallWatchdog.mark("starting the xcuitest bridge for \(udid) (nothing was listening)")
        Self.logStderr("bridge recovery: nothing listens for \(udid) — starting its xcuitest bridge and resolving the call again")
        let spec = DeviceSpec(name: udid, udid: udid, engine: "xcuitest")
        do {
            guard let provisioned = try await BridgeProvisioner(repoRoot: repoRoot)
                .provision(devices: [(udid, spec)], log: Self.logStderr).first else {
                sessions[sessionKey, default: DeviceSession()].simulatorBridgeRebuildFailedUDIDs.insert(udid)
                Self.logStderr("bridge recovery: provisioning returned no bridge for \(udid) — not retried again this session")
                return nil
            }
            Self.logStderr("bridge recovery: started the xcuitest bridge on port \(provisioned.port) for \(udid)")
            return provisioned.port
        } catch {
            sessions[sessionKey, default: DeviceSession()].simulatorBridgeRebuildFailedUDIDs.insert(udid)
            Self.logStderr("bridge recovery: could not start the xcuitest bridge for \(udid)"
                + " (\(error.localizedDescription)) — not retried again this session")
            return nil
        }
    }

    /// **純粋関数**: xcuitest ランナーの測り直しを撃つかの判定材料(エンジン・実機の絞り込みは RunnerMidRunRecheck.target と同じ)と、
    /// **他のセッションが使っているデバイスを除くこと**(`heldByAnotherSession`。起動し直すのはそのセッションのランナー。
    /// run 自身は RunnerMidRunRecheck で自分のレーンを測り直す)。**所要の門は持たない** —— 撃つのは起動の入口だけで、
    /// そこでは常に1問(健全なら 0.1〜0.2s)測る
    static func shouldAttemptXCUITestRunnerRecheck(
        engine: String?, isPhysical: Bool?, injected: Bool, heldByAnotherSession: Bool
    ) -> Bool {
        guard engine == "xcuitest", isPhysical == false, !heldByAnotherSession else { return false }
        return true
    }

    /// **ft_launch / ft_clear_app_data の入口で**、そのデバイスのランナーを1問測り、劣化していれば SpringBoard とランナーを
    /// 起こし直す(`BridgeProvisioner.recheckRunner` = run の RunnerMidRunRecheck と同じ経路)。
    /// **入口だけで撃つ**(ユーザー決定): 起こし直しは前面のアプリも落とすので、探索の途中(遅い呼び出しの直後)に撃つと
    /// 探っていた画面が消える。起動の入口ならどうせアプリを起動し直す。戻り値は応答に添える1行(何もしなければ空)
    func recheckXCUITestRunnerBeforeLaunch(args: [String: Any]) async -> String {
        guard makeDriver == nil else { return "" }
        let key = Self.engineKey(args)
        guard let port = connectedPorts[key], let udid = udids[key] ?? nil,
              let repoRoot = try? RepoRoot.find() else { return "" }
        let injected = RunnerAccessibilityHealth.injectedSlowPorts().contains(port)
        let heldByAnotherSession = Self.heldByAnotherSession(udid: udid, repoRoot: repoRoot)
        guard Self.shouldAttemptXCUITestRunnerRecheck(
                  engine: engines[key], isPhysical: SimulatorCatalog.isPhysical(udid: udid),
                  injected: injected, heldByAnotherSession: heldByAnotherSession)
        else {
            if heldByAnotherSession {
                Self.logStderr(Self.skippedForAnotherSessionMessage(
                    action: "rechecking/restarting", udid: udid, port: port))
            }
            return ""
        }
        SlowCallWatchdog.mark("checking the simulator's SpringBoard before launching")
        let result = await BridgeProvisioner(repoRoot: repoRoot).recheckRunner(
            name: udid, udid: udid, port: port, injected: injected, log: Self.logStderr)
        switch result.outcome {
        case .healthy, .unmeasured, .skipped:
            return ""
        case .restarted(let afterSeconds):
            let before: String
            if case .answered(let seconds) = result.probe { before = String(format: "%.1fs", seconds) } else { before = "slow" }
            let now = afterSeconds.map { String(format: "%.2fs", $0) } ?? "not measured"
            return "note: this simulator's SpringBoard was slow (a system-alert query took \(before); normal is under"
                + " 0.3s, and every tap pays it), so SpringBoard and the XCUITest bridge were restarted before"
                + " continuing (now \(now)).\n"
        case .restartDidNotHelp:
            return "note: this simulator's SpringBoard is slow (a system-alert query takes over 2s; every tap pays it)"
                + " and restarting SpringBoard did not help — rebooting the simulator is the next thing to try.\n"
        case .unusable(let waited):
            return "note: this simulator's SpringBoard did not answer a system-alert query within \(Int(waited.rounded()))s"
                + " even after SpringBoard and the XCUITest bridge were restarted — reboot the simulator"
                + " (`fleetest api wipe-device --platform ios --udid \(udid)` erases it).\n"
        case .restartFailed(let reason):
            Self.logStderr("⚠️ \(udid): could not restart SpringBoard / the xcuitest bridge on port \(port) (\(reason))")
            return ""
        }
    }
}
