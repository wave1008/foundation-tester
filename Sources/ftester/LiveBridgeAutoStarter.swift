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
    private var state: State = .idle
    private var consecutiveFailures = 0

    init(repoRoot: URL, udid: String, port: UInt16) {
        self.repoRoot = repoRoot
        self.udid = udid
        self.port = port
    }

    /// 接続拒否を観測したとき呼ぶ。idle なら起動タスクを開始する(starting/failed 中は何もしない
    /// = xcodebuild の二重起動を防ぐ)。戻り値は更新後の状態サフィックス
    func noteConnectionRefused() -> String {
        if case .idle = state {
            state = .starting
            logStderr("接続拒否を検知したためブリッジを自動起動します(udid: \(udid), port: \(port))")
            let repoRoot = self.repoRoot
            let udid = self.udid
            let port = self.port
            Task.detached { [weak self] in
                let result = await Self.launchBridge(repoRoot: repoRoot, udid: udid, port: port)
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
        let client = BridgeClient(port: port, timeoutSeconds: 3)
        guard let status = try? await client.status() else { return }
        if status.ready && status.protocolVersion == BridgeAPI.bridgeProtocolVersion { return }
        guard case .idle = state else { return }
        state = .starting
        let actual = status.protocolVersion.map(String.init) ?? "なし"
        logStderr("旧ビルドのブリッジ(port \(port))を検知したため再起動します" +
            "(version: \(actual) → \(BridgeAPI.bridgeProtocolVersion))")
        let repoRoot = self.repoRoot
        let udid = self.udid
        let port = self.port
        Task.detached { [weak self] in
            let result = await Self.launchBridge(
                repoRoot: repoRoot, udid: udid, port: port, stopFirst: true)
            await self?.finishLaunch(result: result)
        }
    }

    private func suffix() -> String {
        switch state {
        case .idle:
            return ""
        case .starting:
            return "(XCUITest ブリッジを自動起動しています。初回はビルドに数分かかります。" +
                "準備でき次第この画面は自動復帰します)"
        case .failed(let detail):
            return "(ブリッジの自動起動に失敗しました: \(detail)。" +
                "`ftester bridge up --device \(udid) --port \(port)` を実行してください)"
        }
    }

    private func finishLaunch(result: Result<Void, Error>) {
        switch result {
        case .success:
            state = .idle
            consecutiveFailures = 0
            logStderr("ブリッジの自動起動に成功しました(udid: \(udid), port: \(port))")
        case .failure(let error):
            consecutiveFailures += 1
            let detail = error.localizedDescription
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                state = .failed(detail)
                logStderr("ブリッジの自動起動が\(consecutiveFailures)回連続で失敗したため停止します: " +
                    "\(detail)")
            } else {
                state = .idle  // 次の noteConnectionRefused で再試行を許可する
                logStderr("ブリッジの自動起動に失敗しました(\(consecutiveFailures)回目、再試行可): \(detail)")
            }
        }
    }

    /// actor の外で実行する起動処理本体。失敗時は起動途中のプロセス・pid ファイルを後始末する
    /// (BridgeProvisioner.provisionBridge と同じ理由: 残すと以後のポート採番を汚す)
    private static func launchBridge(
        repoRoot: URL, udid: String, port: UInt16, stopFirst: Bool = false
    ) async -> Result<Void, Error> {
        let launcher = BridgeLauncher(repoRoot: repoRoot, device: udid, port: port)
        do {
            if stopFirst {
                do {
                    try await launcher.stopAndWait()
                } catch LauncherError.notRunning {
                    // pid ファイル無し = このリポジトリ管理外のプロセスがポートを握っている。
                    // ここで startDetached に進むとポート衝突で旧 /status を拾い偽成功になる
                    return .failure(AutoStarterError.staleStopFailed(port: port))
                }
            }
            try launcher.generateProjectIfNeeded()
            do {
                try launcher.startDetached()
            } catch LauncherError.xctestrunNotFound {
                try launcher.buildForTesting()
                try launcher.startDetached()
            }
            try await launcher.waitUntilReady()
            return .success(())
        } catch {
            try? launcher.stop()
            return .failure(error)
        }
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data(("[live serve] " + message + "\n").utf8))
    }
}

private enum AutoStarterError: Error, LocalizedError {
    case staleStopFailed(port: UInt16)

    var errorDescription: String? {
        switch self {
        case .staleStopFailed(let port):
            return "旧ブリッジを停止できません(pid ファイルなし)。" +
                "`ftester bridge down --port \(port)` を実行してください"
        }
    }
}
