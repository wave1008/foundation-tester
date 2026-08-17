// RemoteDispatchLock.swift
// 同一リモートホストへの二重ディスパッチ防止(docs/remote-runner.md §5「ジョブは直列化」)。
// フリート内の重複は FleetProfile.validate で防げるが、別フリート・別人・CLI/GUI 併走による
// 同一ホストへの二重実行は防げない ―― そこをリモート側のロックファイルで塞ぐ。
// ssh 実行・プロセス起動はここに置かない(呼び出し側 = Sources/ftester/RemoteRunDispatcher.swift)。
// ここは①ロックの中身の組み立て・解析②ssh で叩く1本のコマンド文字列の組み立て、だけを行う
// 純粋関数(結果は完全一致でテストする)。

import Foundation

/// ロック取得側(ローカル)の情報。`<base>/.ftester/dispatch.lock/info.json` の中身
public struct RemoteDispatchLockInfo: Codable, Equatable, Sendable {
    /// 発行側(ローカル、= ディスパッチを実行しているマシン)のホスト名。
    /// 「誰が掴んでいるか」を人間へ示すための表示専用の値で、照合には使わない
    public let issuerHost: String
    /// 発行側の pid。**リモート側からは liveness を確認できない**(別マシンの pid のため
    /// kill(pid,0) は無意味)。表示専用
    public let pid: Int32
    /// 取得時刻(UTC, ISO8601)。表示専用 ―― stale 判定に時刻を機械的には使わない
    /// (docs/remote-runner.md §5「既定では奪わない」。長時間 run を誤って殺さないため)
    public let acquiredAt: String

    public init(issuerHost: String, pid: Int32, acquiredAt: String) {
        self.issuerHost = issuerHost
        self.pid = pid
        self.acquiredAt = acquiredAt
    }

    public static func now(issuerHost: String, pid: Int32, date: Date = Date()) -> RemoteDispatchLockInfo {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return RemoteDispatchLockInfo(issuerHost: issuerHost, pid: pid, acquiredAt: formatter.string(from: date))
    }
}

public enum RemoteDispatchLock {

    /// **プロジェクト非依存・ホストに1本**(TestProject.stateDir 配下の per-project `.ftester/`
    /// とは別物 ―― 競合はデバイスというホスト全体の資源を巡るもので、プロジェクト単位ではない)
    public static func lockDirPath(base: String) -> String {
        base + "/.ftester/dispatch.lock"
    }

    public static func infoFilePath(base: String) -> String {
        lockDirPath(base: base) + "/info.json"
    }

    public static func encode(_ info: RemoteDispatchLockInfo) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(info) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String) -> RemoteDispatchLockInfo? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteDispatchLockInfo.self, from: data)
    }

    /// 取得失敗時に出す1行。「誰がいつから掴んでいるか」+ どうすればよいか
    /// (相手の完了を待つ / stuck なら --force-lock で奪う)を必ず含める
    public static func heldMessage(_ info: RemoteDispatchLockInfo?) -> String {
        let holder = info.map { "started by \($0.issuerHost) (pid \($0.pid)) at \($0.acquiredAt)" }
            ?? "holder unknown (its lock info could not be read)"
        return "another dispatch is already running on this remote host (\(holder))"
            + " — wait for it to finish, or pass --force-lock if it is stuck"
            + " (docs/remote-runner.md §5)"
    }

    // MARK: - ssh コマンド組み立て(純粋関数。$ とバッククォートは RemoteShell.quote が
    // シングルクォートで無害化する ―― JSON 本文にそれらの文字が来ても展開されない)

    /// 取得コマンド。**`mkdir <leaf>` の原子性がロックの実体**(`test -e` → 作成の2段は
    /// 競合に対して無意味 ―― docs/remote-runner.md §5)。親ディレクトリ(.ftester/)だけは
    /// `mkdir -p` で先に用意する(-p は「既存なら成功」なので、こちらに原子性を持たせては
    /// いけない。leaf の `mkdir` に -p を付けないのはそのため)。mkdir が失敗(既存)すれば
    /// この1本のコマンド全体が非0で終わり、info.json は書かれない
    public static func acquireCommand(base: String, info: RemoteDispatchLockInfo) -> String {
        let parent = RemoteShell.quote(base + "/.ftester")
        let leaf = RemoteShell.quote(lockDirPath(base: base))
        let writeInfo = writeInfoCommand(base: base, info: info)
        return "mkdir -p \(parent) && mkdir \(leaf) 2>/dev/null && \(writeInfo)"
    }

    /// `--force-lock`: 既存のロックを丸ごと消してから通常の取得コマンドを続ける。
    /// **既定では奪わない**(stale 判定を時刻だけで機械的に行わない。呼び出し側は
    /// 明示フラグのときだけこちらを使う)
    public static func forceAcquireCommand(base: String, info: RemoteDispatchLockInfo) -> String {
        "rm -rf \(RemoteShell.quote(lockDirPath(base: base))) && \(acquireCommand(base: base, info: info))"
    }

    /// 既存ロックの中身を読む(取得失敗時に「誰が掴んでいるか」を示すため)。
    /// ファイル不在でもコマンド自体の exit code は 0 にする(`|| true`) ――
    /// 「読めなかった」を ssh 自体の失敗と区別するため、呼び出し側は出力の有無だけで判定できる
    public static func readCommand(base: String) -> String {
        "cat \(RemoteShell.quote(infoFilePath(base: base))) 2>/dev/null || true"
    }

    /// 解放。成功・失敗・タイムアウト・例外いずれでも呼ぶのが呼び出し側の契約(defer で保証)。
    /// 存在しない場合も -f で無害
    public static func releaseCommand(base: String) -> String {
        "rm -rf \(RemoteShell.quote(lockDirPath(base: base)))"
    }

    private static func writeInfoCommand(base: String, info: RemoteDispatchLockInfo) -> String {
        let payload = encode(info) ?? "{}"
        return "printf '%s' \(RemoteShell.quote(payload)) > \(RemoteShell.quote(infoFilePath(base: base)))"
    }
}
