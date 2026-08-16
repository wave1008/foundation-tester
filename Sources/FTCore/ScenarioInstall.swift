// ScenarioInstall.swift
// installApp() の子→親 RPC(2026-08-03 決定: インストールの実行はオーケストレータ[親]の仕事)。
// プロトコル:
//   子→親(stdout NDJSON ScenarioEvent, kind="installRequest"): requestID・installPath(nil可)。
//     ScenarioHost.run が横取りして処理する(ScenarioEvent.swift のコメント参照)。
//   親→子(stdin, NDJSON 1 行): {"cmd":"installResult","id":<requestID>,"ok":true|false,"message":"..."}
// 子側の待機はこのファイルの ScenarioInstallControl(FTDriveCore.installControl に注入。
// FTDSL の installApp() が使う)。親側の実行と応答は ScenarioHost.run(installHandler:)。

import Foundation

/// ランナー側(子)の RPC 待機機構。1 リクエスト = 1 continuation。stdin 読み取りスレッドからの
/// resolve と DSL 側の request が別スレッドから触るため actor で直列化する
public actor ScenarioInstallControl {
    public struct Result: Sendable {
        public let ok: Bool
        public let message: String
        public init(ok: Bool, message: String) {
            self.ok = ok
            self.message = message
        }
    }

    private var pending: [Int: CheckedContinuation<Result, Never>] = [:]
    private var nextID = 0

    public init() {}

    /// installApp() が呼ぶ: id を発番し、continuation を登録してから emit(id) で
    /// installRequest イベントを送出し、応答を待つ。登録と emit は withCheckedContinuation の
    /// クロージャ内(サスペンド前・actor 分離のまま)で行うため、応答が登録前に届いて
    /// 取りこぼす競合は起きない。timeoutSeconds 経過で自動的に ok:false へ解決する
    /// (呼び出し側は FTSync.commandTimeout の外枠より内側の値を渡すこと — 外枠だと汎用の
    /// "operation timed out" になり installApp 固有の事情が消える)
    public func request(timeoutSeconds: Double, emit: (Int) -> Void) async -> Result {
        nextID += 1
        let id = nextID
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
            await self?.timeoutIfPending(id: id)
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            pending[id] = cont
            emit(id)
        }
        timeoutTask.cancel()
        return result
    }

    /// stdin 読み取りスレッドから呼ぶ(parse(line:) 済みの id/ok/message)
    public func resolve(id: Int, ok: Bool, message: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(returning: Result(ok: ok, message: message))
    }

    private func timeoutIfPending(id: Int) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(returning: Result(
            ok: false, message: "installApp: no response from the orchestrator within the timeout"))
    }

    /// stdin の 1 行を installResult としてパースする(cmd フィールドで判別。debug の制御コマンドと
    /// 同じ stdin を共有するため、該当しなければ nil を返し呼び出し側が ScenarioDebugControl.apply
    /// へ委譲する。同期・純粋関数なので単体テストで固定できる)
    public nonisolated static func parse(line: String) -> (id: Int, ok: Bool, message: String)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String, cmd == "installResult",
              let id = object["id"] as? Int else { return nil }
        let ok = object["ok"] as? Bool ?? false
        let message = object["message"] as? String ?? ""
        return (id, ok, message)
    }
}
