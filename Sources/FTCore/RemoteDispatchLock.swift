// RemoteDispatchLock.swift
// 同一リモートホストへの二重ディスパッチ防止(docs/remote-runner.md §5「ジョブは直列化」)。
// フリート内の重複は FleetProfile.validate で防げるが、別フリート・別人・CLI/GUI 併走による
// 同一ホストへの二重実行は防げない ―― そこをリモート側のロックファイルで塞ぐ。
// ssh 実行・プロセス起動はここに置かない(呼び出し側 = Sources/fleetest/RemoteRunDispatcher.swift)。
// ここは①ロックの中身の組み立て・解析②ssh で叩く1本のコマンド文字列の組み立て、だけを行う
// 純粋関数(結果は完全一致でテストする)。

import Foundation

/// ロック取得側(ローカル)の情報。`<base>/.fleetest/dispatch.lock/info.json` の中身
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
    /// 自己申告の帰属(LocalConfig.resolveIssuerId)。表示専用。旧 info.json にはキーが無いので
    /// Optional のまま(decodeIfPresent で自動的に nil になる ―― Codable を手書きしない)
    public let issuer: String?

    public init(issuerHost: String, pid: Int32, acquiredAt: String, issuer: String? = nil) {
        self.issuerHost = issuerHost
        self.pid = pid
        self.acquiredAt = acquiredAt
        self.issuer = issuer
    }

    public static func now(issuerHost: String, pid: Int32, issuer: String? = nil,
                           date: Date = Date()) -> RemoteDispatchLockInfo {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return RemoteDispatchLockInfo(issuerHost: issuerHost, pid: pid,
                                      acquiredAt: formatter.string(from: date), issuer: issuer)
    }
}

public enum RemoteDispatchLock {

    /// **プロジェクト非依存・ホストに1本**(TestProject.stateDir 配下の per-project `.fleetest/`
    /// とは別物 ―― 競合はデバイスというホスト全体の資源を巡るもので、プロジェクト単位ではない)
    public static func lockDirPath(base: String) -> String {
        base + "/.fleetest/dispatch.lock"
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
        "another dispatch is already running on this remote host (\(holderDescription(info)))"
            + " — wait for it to finish, run `fleetest remote unlock --host <host>` if it is your own"
            + " dispatch that died, or pass --force-lock if it is stuck"
            + " (docs/remote-runner.md §5)"
    }

    /// align/setup 用の取得失敗メッセージ(docs/remote-runner.md §18.3 規則2)。align/install は
    /// 実行中バイナリを差し替えるので、稼働中の dispatch へ重ねると SIGKILL する。align/setup に
    /// `--force-lock` は無い(stale 判定を機械的に行わない既定を、稼働中バイナリの差し替えという
    /// 一段重い操作でまで崩さない)ので、heldMessage と違い --force-lock は案内しない
    public static func alignHeldMessage(_ info: RemoteDispatchLockInfo?) -> String {
        "another dispatch is running on this remote host (\(holderDescription(info)))"
            + " — aligning now would replace the binary under the running dispatch and kill it."
            + " Wait for it to finish and retry (docs/remote-runner.md §18.3)"
    }

    private static func holderDescription(_ info: RemoteDispatchLockInfo?) -> String {
        guard let info else { return "holder unknown (its lock info could not be read)" }
        if let issuer = info.issuer {
            return "started by \(issuer) (from \(info.issuerHost), pid \(info.pid)) at \(info.acquiredAt)"
        }
        return "started by \(info.issuerHost) (pid \(info.pid)) at \(info.acquiredAt)"
    }

    /// wait-lock の初回・進捗ログ用(heldMessage/alignHeldMessage と同じ holder 表現を再利用する)
    public static func holderSummary(_ info: RemoteDispatchLockInfo?) -> String {
        holderDescription(info)
    }

    // MARK: - ssh コマンド組み立て(純粋関数。$ とバッククォートは RemoteShell.quote が
    // シングルクォートで無害化する ―― JSON 本文にそれらの文字が来ても展開されない)

    /// 取得コマンド。**`mkdir <leaf>` の原子性がロックの実体**(`test -e` → 作成の2段は
    /// 競合に対して無意味 ―― docs/remote-runner.md §5)。親ディレクトリ(.fleetest/)だけは
    /// `mkdir -p` で先に用意する(-p は「既存なら成功」なので、こちらに原子性を持たせては
    /// いけない。leaf の `mkdir` に -p を付けないのはそのため)。mkdir が失敗(既存)すれば
    /// この1本のコマンド全体が非0で終わり、info.json は書かれない
    public static func acquireCommand(base: String, info: RemoteDispatchLockInfo) -> String {
        let parent = RemoteShell.quote(base + "/.fleetest")
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

    /// `remote unlock` 用: ロックの有無と中身を1往復で読む。1行目が `absent`(ロック無し)か
    /// `held`(有り。2行目以降が info.json。読めなければ空)
    public static func probeCommand(base: String) -> String {
        let dir = RemoteShell.quote(lockDirPath(base: base))
        let info = RemoteShell.quote(infoFilePath(base: base))
        return "if [ -d \(dir) ]; then echo held; cat \(info) 2>/dev/null || true; else echo absent; fi"
    }

    private static func writeInfoCommand(base: String, info: RemoteDispatchLockInfo) -> String {
        let payload = encode(info) ?? "{}"
        return "printf '%s' \(RemoteShell.quote(payload)) > \(RemoteShell.quote(infoFilePath(base: base)))"
    }

    public enum Probe: Equatable, Sendable {
        case absent
        case held(RemoteDispatchLockInfo?)
    }

    public static func parseProbe(_ output: String) -> Probe? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        lines.removeFirst()
        switch first {
        case "absent": return .absent
        case "held": return .held(decode(lines.joined(separator: "\n")))
        default: return nil
        }
    }
}

/// `fleetest remote unlock`: **自分の死んだディスパッチが残したロックだけ**を外す判定(純粋関数)。
/// `--force-lock` は他人の走っている run を奪えるので、残ったロックの片付けにそれを使わせない
/// (受け手要望 2026-08-23: 複数人でフリートを共有すると、残ったロック + --force-lock が事故になる)。
///
/// 規則(上から順に最初に当たったもの):
/// - ロック無し → 何もしない
/// - info が読めない → 外さない(「情報が読めなくてもロック自体は尊重する」の既存規則)
/// - 発行者が違う(issuer 不一致、または旧 info で issuer 無し) → 外さない
/// - 同じ発行者で、発行元がこの機械(issuerHost 一致)かつその pid がまだ生きている → 外さない
///   (動いている自分の run のロック。止めれば自分で解放する)
/// - それ以外(同じ発行者で、pid が死んでいる / 別の機械から発行した) → 外す
///   **別の機械の pid の生死はここからは見えない**ので、発行者が自分なら本人の申告として外す
public enum RemoteDispatchUnlock {
    public enum Decision: Equatable, Sendable {
        case nothingToDo
        case release(reason: String)
        case refuse(reason: String)
    }

    public static func decide(probe: RemoteDispatchLock.Probe, myIssuer: String, myHost: String,
                              pidAlive: (Int32) -> Bool) -> Decision {
        switch probe {
        case .absent:
            return .nothingToDo
        case .held(nil):
            return .refuse(reason: "the lock's info.json could not be read, so its owner is unknown"
                + " — if you are sure no dispatch is running there, pass --force-lock on your next dispatch")
        case .held(let info?):
            guard let issuer = info.issuer, issuer == myIssuer else {
                let holder = info.issuer.map { "\($0) (from \(info.issuerHost), pid \(info.pid))" }
                    ?? "\(info.issuerHost) (pid \(info.pid), no issuer recorded)"
                return .refuse(reason: "the lock is held by \(holder), not by you (\(myIssuer))"
                    + " — only the owner can unlock it; --force-lock steals it and may kill their run")
            }
            // ホスト名は大文字小文字を区別しない(ProcessInfo.hostName は小文字・`hostname` は
            // 大文字で返すことがある。同じ機械を別物と見ると、生きている自分の run のロックを外す)
            let sameHost = info.issuerHost.caseInsensitiveCompare(myHost) == .orderedSame
            if sameHost, pidAlive(info.pid) {
                return .refuse(reason: "your dispatch (pid \(info.pid)) is still running on this machine"
                    + " — stop it and it releases the lock itself")
            }
            let why = sameHost
                ? "your dispatch (pid \(info.pid)) is no longer running on this machine"
                : "it was acquired by you from \(info.issuerHost) (pid \(info.pid) — not checkable from here)"
            return .release(reason: why)
        }
    }
}
