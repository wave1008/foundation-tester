// RemoteDispatchLock.swift
// **1つの Mac で同時に走る run は1本**(ユーザー決定 2026-09-21。高負荷はテストを不安定にする)を
// 守るロック。docs/remote-runner.md §5「ジョブは直列化」。
// フリート内の重複は FleetProfile.validate で防げるが、別フリート・別人・CLI/GUI 併走による
// 同一ホストへの二重実行は防げない ―― そこをその機械のロックファイルで塞ぐ。
// **手元で直接打った run も同じロックを取る**(Sources/fleetest/LocalDispatchLock.swift。
// 取らないと、他人がこの Mac をランナーとして登録している間、他人のディスパッチと手元の run が
// 同じ CoreSimulatorService と同じ loopback のポートを奪い合う)。
// ssh 実行・プロセス起動はここに置かない(呼び出し側 = Sources/fleetest/RemoteRunDispatcher.swift /
// LocalDispatchLock.swift)。ここは①ロックの中身の組み立て・解析②シェルで叩く1本のコマンド
// 文字列の組み立て、だけを行う純粋関数(結果は完全一致でテストする)。

import Foundation
import FTCore

/// ロックがどの機械のものかで**文言だけ**を分ける(判定・コマンドは同じものを通す)。
/// 逃げ道の案内が違うので1つの文には畳めない —— リモートは `remote unlock --runner <machine>`、
/// 手元は**次の run が pid の生死で自動回収する**(`RemoteDispatchUnlock.decideLocalSweep`。
/// 待たずに今すぐ外すなら `remote unlock --runner local` = `decideThisMachine`)
public enum DispatchLockScope: Equatable, Sendable {
    case remoteHost
    case thisMachine
}

/// ロック取得側(ローカル)の情報。`<home>/.fleetest/dispatch.lock/info.json` の中身
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

    /// **プロジェクト非依存・機械に1本**(TestProject.stateDir 配下の per-project `.fleetest/`
    /// とは別物 ―― 競合はデバイスというホスト全体の資源を巡るもので、プロジェクト単位ではない)。
    ///
    /// **置き場は `<base>` ではなく `$HOME`**(`FTCore.MachineStateDirectory`)。base は
    /// `--remote-dir` / 登録簿 / 既定の `~/fleetest-runner` で変わるので、同じ Mac に base を
    /// 2つ作るとロックが2本になる ―― しかし2つの run が取り合うのは**同じ
    /// CoreSimulatorService と同じ loopback のポート**なので、排他が成立せず黙って壊れる。
    /// 守りたいのは `<base>` ではなく**その機械の資源**なので、機械グローバルな区画へ置く。
    ///
    /// `home` は**そのロックが守る機械のホーム**(リモートなら ssh 先の `$HOME` を手元で
    /// 確定した絶対パス。`RemoteLayout.home`)
    public static func lockDirPath(home: String) -> String {
        MachineStateDirectory.path(home: home) + "/dispatch.lock"
    }

    public static func infoFilePath(home: String) -> String {
        lockDirPath(home: home) + "/info.json"
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
    /// (相手の完了を待つ / stuck なら --force-lock で奪う)を必ず含める。
    /// **`scope` は文言だけを分ける**(既定はリモート = 従来と1バイトも変わらない)
    public static func heldMessage(_ info: RemoteDispatchLockInfo?,
                                   scope: DispatchLockScope = .remoteHost) -> String {
        switch scope {
        case .remoteHost:
            return "another dispatch is already running on this remote host (\(holderDescription(info)))"
                + " — wait for it to finish, run `fleetest remote unlock --runner <machine>` if it is your own"
                + " dispatch that died, or pass --force-lock if it is stuck"
                + " (docs/remote-runner.md §5)"
        case .thisMachine:
            // `remote unlock` は案内しない —— 手元のロックは同じ機械の pid なので、死んでいれば
            // 次の run が自分で回収する(decideLocalSweep)。残っているなら生きている run のもの
            return "another fleetest run is already running on this Mac (\(holderDescription(info)))"
                + " — this machine runs one run at a time (two runs fight over the same"
                + " CoreSimulatorService and the same loopback ports). Wait for it to finish,"
                + " or pass --wait-lock <seconds> to queue for it"
                + " (docs/remote-runner.md §5)"
        }
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
    public static func acquireCommand(home: String, info: RemoteDispatchLockInfo) -> String {
        let parent = RemoteShell.quote(MachineStateDirectory.path(home: home))
        let leaf = RemoteShell.quote(lockDirPath(home: home))
        let writeInfo = writeInfoCommand(home: home, info: info)
        return "mkdir -p \(parent) && mkdir \(leaf) 2>/dev/null && \(writeInfo)"
    }

    /// `--force-lock`: 既存のロックを丸ごと消してから通常の取得コマンドを続ける。
    /// **既定では奪わない**(stale 判定を時刻だけで機械的に行わない。呼び出し側は
    /// 明示フラグのときだけこちらを使う)
    public static func forceAcquireCommand(home: String, info: RemoteDispatchLockInfo) -> String {
        "rm -rf \(RemoteShell.quote(lockDirPath(home: home))) && \(acquireCommand(home: home, info: info))"
    }

    /// 既存ロックの中身を読む(取得失敗時に「誰が掴んでいるか」を示すため)。
    /// ファイル不在でもコマンド自体の exit code は 0 にする(`|| true`) ――
    /// 「読めなかった」を ssh 自体の失敗と区別するため、呼び出し側は出力の有無だけで判定できる
    public static func readCommand(home: String) -> String {
        "cat \(RemoteShell.quote(infoFilePath(home: home))) 2>/dev/null || true"
    }

    /// 解放。成功・失敗・タイムアウト・例外いずれでも呼ぶのが呼び出し側の契約(defer で保証)。
    /// 存在しない場合も -f で無害
    public static func releaseCommand(home: String) -> String {
        "rm -rf \(RemoteShell.quote(lockDirPath(home: home)))"
    }

    /// `remote unlock` 用: ロックの有無と中身を1往復で読む。1行目が `absent`(ロック無し)か
    /// `held`(有り。2行目以降が info.json。読めなければ空)
    public static func probeCommand(home: String) -> String {
        let dir = RemoteShell.quote(lockDirPath(home: home))
        let info = RemoteShell.quote(infoFilePath(home: home))
        return "if [ -d \(dir) ]; then echo held; cat \(info) 2>/dev/null || true; else echo absent; fi"
    }

    /// ランナー上で**ディスパッチが起こした run がまだ生きているか**を見る(生きている pid を1行1つで出す)。
    /// ディスパッチの run は必ず `--report-dir <base>/users/<issuer>/work/.fleetest/dispatch/<stamp>/reports`
    /// を引数に持つ(RemoteLayout.dispatchReportDir)ので、その形の引数を持つプロセスを pgrep する。
    /// この pgrep を起動したシェル(コマンド行にこの式を含む)は一致しない —— macOS の pgrep は既定で
    /// 自分と祖先を除く(pgrep(1) の `-a`。ランナーは macOS。`testProbeFindsOnlyADispatchedRunOnARealProcessTable`)。
    /// 一致なし(pgrep の終了コード 1)は `|| true` で 0 にする(ssh の失敗 = 255 と区別するため)
    public static func liveDispatchedRunsCommand(base: String) -> String {
        let pattern = regexEscaped(base) + "/users/[^ /]+/work/" + regexEscaped(".fleetest/dispatch/")
        return "pgrep -f -- \(RemoteShell.quote(pattern)) || true"
    }

    /// **base を絞らない**同じ pgrep(組み立ては `liveDispatchedRunsCommand` の1つを通す ——
    /// base を空にしたパターンは base 指定版の**上位集合**なので、外れるとしても「拾いすぎる」側)。
    ///
    /// 用途は `remote unlock --runner local`(= この Mac に他人が置いたロックの生死を手元で見る)
    /// だけ。**発行側の `--remote-dir` は info.json に残らない**ので、ここで既定の
    /// `~/fleetest-runner` を仮定すると、別の base へ撃たれた**生きている**ディスパッチが
    /// 「run は居ない」と答え、守っている run のロックを外してしまう(= 1機械1 run の不変条件が
    /// 黙って壊れる)。拾いすぎて外さないほうは、待つか次の run の自動回収で解ける
    public static func liveDispatchedRunsAnyBaseCommand() -> String {
        liveDispatchedRunsCommand(base: "")
    }

    /// このディスパッチの run(`--report-dir <reportDir>` を引数に持つプロセス)がランナー上に
    /// まだ残っているかの pgrep 条件式(単体では実行しない部品)。pgrep が自分と祖先を除く点は
    /// `liveDispatchedRunsCommand` と同じ
    private static func runAlivePgrepCondition(reportDir: String) -> String {
        "pgrep -f -- \(RemoteShell.quote(regexEscaped(reportDir))) >/dev/null"
    }

    /// 中断したディスパッチが**回収へ入る前に**ロックを外す 1 往復。このディスパッチの run が
    /// ランナーに残っていれば外さず `busy`、居なければ外して `released` を出す。**居るかを見るのは
    /// 中断で ssh が先に切れうるから**(向こうの run はまだ後始末中かもしれない = 外すと同じ台に
    /// 2 本目が乗る)
    public static func releaseIfRunEndedCommand(home: String, reportDir: String) -> String {
        "if \(runAlivePgrepCondition(reportDir: reportDir)); then echo busy;"
            + " else \(releaseCommand(home: home)) && echo released; fi"
    }

    /// `releaseIfRunEndedCommand` の出力が「外した」か。それ以外(busy・空・想定外)は外していない側
    public static func releasedEarly(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "released"
    }

    /// M7: ディスパッチの ssh(-tt)が自分から中断したのでも exit 0/1 でもない形で終わった
    /// (ssh の断・kill = 255/137 等)ときに、**ロックは外さず**このディスパッチの run が
    /// ランナー上で終わっているかだけを見る 1 往復。`releaseIfRunEndedCommand` と同じ pgrep 判定を
    /// 共有する(判定を2箇所に持たない)。releasedEarly の "released" と混同しないよう別の語を返す
    public static func runEndedCommand(reportDir: String) -> String {
        "if \(runAlivePgrepCondition(reportDir: reportDir)); then echo busy; else echo ended; fi"
    }

    /// `runEndedCommand` の出力が「終わっていた」か
    public static func runHasEnded(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "ended"
    }

    public static func parseLivePIDs(_ output: String) -> [Int32] {
        output.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func regexEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\.^$|?*+()[]{}".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func writeInfoCommand(home: String, info: RemoteDispatchLockInfo) -> String {
        let payload = encode(info) ?? "{}"
        return "printf '%s' \(RemoteShell.quote(payload)) > \(RemoteShell.quote(infoFilePath(home: home)))"
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
                let holder = holderPhrase(info)
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

    /// release の判定に「ランナー上でディスパッチの run がまだ生きていないか」を掛ける(3つの呼び口 =
    /// 次のディスパッチの自動回収・モニター起動時の掃除・`remote unlock` が共有する)。
    /// **手元の pid が死んでいてもリモートの run は生きていることがある** —— `kill -9` 等で後始末が
    /// 走らないと、手元の ssh が孤児として残り、リモートの run は最後まで流れる(実測)。そこでロックを
    /// 外すと同じ台へ2本目が乗る。`livePIDs == nil`(確かめられなかった)も外さない(不明を空きに倒さない)。
    ///
    /// **`scope` は文言だけを分ける**(`RemoteDispatchLock.heldMessage` と同じ規律)。`.thisMachine`
    /// は「この Mac へ他人が撃ったディスパッチの run を手元の pgrep で見た」側で、逃げ道も違う ——
    /// 他人のロックは次の自分の run では回収されない(`decideLocalSweep` が issuer 違いを断る)ので、
    /// 「次のディスパッチが自動で外す」とは言えない
    public static func guardingLiveRemoteRun(_ decision: Decision, livePIDs: [Int32]?,
                                             scope: DispatchLockScope = .remoteHost) -> Decision {
        guard case .release = decision else { return decision }
        guard let livePIDs else {
            switch scope {
            case .remoteHost:
                return .refuse(reason: "could not check whether the run that dispatch started is still"
                    + " running on the runner")
            case .thisMachine:
                return .refuse(reason: "could not check whether a run dispatched to this Mac is still"
                    + " running here")
            }
        }
        guard livePIDs.isEmpty else {
            let pids = livePIDs.map(String.init).joined(separator: ", ")
            switch scope {
            case .remoteHost:
                return .refuse(reason: "the run that dispatch started is still running on the runner"
                    + " (pid \(pids)) — its local side died but"
                    + " that run did not. Wait for it to finish; the next dispatch then releases the lock"
                    + " automatically")
            case .thisMachine:
                return .refuse(reason: "a run dispatched to this Mac is still running here"
                    + " (pid \(pids)) — the Mac that started it may be gone, but that run is not."
                    + " Wait for it to finish; it releases the lock itself when it does")
            }
        }
        return decision
    }

    /// **同じ機械のロック**(手元で直接打った run が取ったもの)の自動回収。
    ///
    /// **リモートとの非対称の理由**: `guardingLiveRemoteRun` は「発行側の pid がランナーから
    /// 見えない」ことの埋め合わせで、その裏取り(`liveDispatchedRunsCommand`)は
    /// `<base>/users/<issuer>/work/.fleetest/dispatch/` 形の `--report-dir` を持つ run しか
    /// pgrep できない。**手元の run はその形を持たない**ので、掛けると答えが常に
    /// 「確かめられなかった」= 外さない側に倒れ、**死んだローカルのロックが永久に残る**。
    /// 同じ機械の pid は `FTCore.ProcessLiveness.isAlive` で**確定できる** ——
    /// リモートの裏取りより強い判定なので、掛けないほうが安全側。
    ///
    /// 規則そのものは `decideAutomaticSweep` と同じ1つを通す(2つ目の回収規則を作らない)。
    /// **他人がこの Mac へディスパッチして置いたロックは外さない** —— その控えは相手の issuer と
    /// 相手の issuerHost を名乗るので、同じ規則(発行者違い / 別の機械から発行)で refuse に落ちる
    public static func decideLocalSweep(probe: RemoteDispatchLock.Probe, myIssuer: String,
                                        myHost: String, pidAlive: (Int32) -> Bool) -> Decision {
        decideAutomaticSweep(probe: probe, myIssuer: myIssuer, myHost: myHost, pidAlive: pidAlive)
    }

    /// `fleetest remote unlock --runner local`: **この Mac の** dispatch.lock を今すぐ外してよいか。
    /// 自動回収(`decideLocalSweep`)は次の run が走るまで動かないので、他人のディスパッチを
    /// 待たせている残骸をその場で片付けるための手動の口。**新しい規則は作らず、控えの
    /// `issuerHost` で既存の2つに振り分けるだけ**:
    ///
    /// - **この機械から取ったロック**(issuerHost 一致 = 手元の run か、この Mac から撃った
    ///   ディスパッチ)→ `decideLocalSweep`。pid が同じ機械のものなので生死で**確定できる**
    ///   (pgrep より強い判定なので裏取りを重ねない。`livePIDs` は呼ばない)
    /// - **別の Mac から撃たれたディスパッチのロック**(issuerHost 不一致)→ 控えの pid は
    ///   向こうの Mac の pid なので見ない。その run は**この機械の上で走っている**ので、
    ///   手元の pgrep(`livePIDs`)だけで決める = `guardingLiveRemoteRun`
    ///
    /// **他人(issuer 違い)のロックも外せる**のが `decide`(= `remote unlock --runner <machine>`)
    /// との差分。向こうの機械では pgrep は pid 判定の**裏取り**でしかないが、こちらでは
    /// 「守っている run がこの機械に居るか」の**確定的な証拠**になる —— 居ないなら、そのロックは
    /// 誰のものでも死んでいる。確かめられなかった(pgrep が撃てなかった)ときは
    /// `guardingLiveRemoteRun` が外さない側へ倒す
    public static func decideThisMachine(probe: RemoteDispatchLock.Probe, myIssuer: String,
                                         myHost: String, pidAlive: (Int32) -> Bool,
                                         livePIDs: () -> [Int32]?) -> Decision {
        switch probe {
        case .absent:
            return .nothingToDo
        case .held(let held):
            // `decide` と同じ規則(読めないロックも尊重する)を手元の言い回しで
            guard let info = held else {
                return .refuse(reason: "the lock's info.json could not be read, so its owner is unknown"
                    + " — if you are sure no run is going on this Mac, pass --force-lock on your next run")
            }
            guard info.issuerHost.caseInsensitiveCompare(myHost) != .orderedSame else {
                return decideLocalSweep(probe: probe, myIssuer: myIssuer, myHost: myHost,
                                        pidAlive: pidAlive)
            }
            let release = Decision.release(
                reason: "it was dispatched to this Mac by \(holderPhrase(info)) and no run it started"
                    + " is left here")
            return guardingLiveRemoteRun(release, livePIDs: livePIDs(), scope: .thisMachine)
        }
    }

    /// 「誰が掴んでいるか」の1句(refuse と release の両方が同じ綴りで名乗る)
    private static func holderPhrase(_ info: RemoteDispatchLockInfo) -> String {
        info.issuer.map { "\($0) (from \(info.issuerHost), pid \(info.pid))" }
            ?? "\(info.issuerHost) (pid \(info.pid), no issuer recorded)"
    }

    /// モニター起動時の**自動掃除**用の判定。手動の unlock より保守側 —— 自分のロックでも
    /// **別の機械から発行したものは触らない**(pid の生死をここから確かめられず、同じ issuer の
    /// 別 Mac の生きている run のロックを外し得る。手動なら本人が判断できるが、自動で外して
    /// よいのは「この機械の自分の pid が死んでいる」と確定できたときだけ)
    public static func decideAutomaticSweep(probe: RemoteDispatchLock.Probe, myIssuer: String,
                                            myHost: String, pidAlive: (Int32) -> Bool) -> Decision {
        let decision = decide(probe: probe, myIssuer: myIssuer, myHost: myHost, pidAlive: pidAlive)
        if case .release = decision, case .held(let info?) = probe,
           info.issuerHost.caseInsensitiveCompare(myHost) != .orderedSame {
            return .refuse(reason: "acquired from \(info.issuerHost) — its liveness cannot be checked"
                + " from this machine; run `fleetest remote unlock` manually if it is dead")
        }
        return decision
    }
}
