// ディスパッチの ssh(`-tt`)を、起こしたプロセス(ディスパッチャ)が死んだら止まるように包む。
//
// macOS には親の死を子へ知らせる仕組み(PDEATHSIG)が無く、ディスパッチャが `kill -9` 等で後始末無しに
// 死ぬと ssh が孤児として残る。孤児の ssh は出力の渡し先を失って channel を読まなくなるので、リモートの run は
// 出力の write で止まったまま終わらない —— dispatch.lock も台も握ったまま、ロックの自動回収も
// (「run がまだ生きている」ので)効かない(実測: 11 分止まり、孤児の ssh を止めた瞬間に完走した)。
//
// 包みの sh は ssh を子に持ち、背景の見張りが 2 秒ごとに「包み自身の親が起動時の pid のままか」を見る。
// 親が死ぬと包みは launchd へ付け替わる(死んだ親がゾンビのままでも付け替えは死んだ時点で起きる)ので、
// 変わっていたら ssh へ SIGTERM を送る(`-tt` がリモートへ SIGHUP を伝え、リモートの run は中断の経路で終わる)。
// 中断は中継を書かなくても ssh へ届く —— InterruptRelay が撃つ `Process.terminate()` は包みの**プロセスグループ**
// ごと届き(Foundation の子はグループリーダー)、ssh も見張りも同じグループに居る(実測)。
// **終了コードは ssh のもの**(呼び手は 90/91/255 で分岐する)。正常終了に遅れを足さない(本体は ssh を wait する)。

public enum ParentBoundCommand {
    /// 親の死に気づくまでの最大秒数(`sleep` の間隔)。短くすると ps を撃つ回数が増えるだけで、
    /// 気づいた後にリモートが止まるまでの時間(SIGHUP → 中断の経路)に比べれば誤差
    public static let pollSeconds = 2

    /// `argv` を包んだ argv(`/bin/sh -c <script> <$0> <parentPID> <argv...>`)
    public static func wrap(_ argv: [String], parentPID: Int32) -> [String] {
        ["/bin/sh", "-c", script, "fleetest-ssh-watch", String(parentPID)] + argv
    }

    /// `$1` = 見張る親の pid。`$$` はサブシェルの中でも包み自身の pid。
    /// **見張りの標準入出力は /dev/null** —— 継がせると、`kill $w` の後も見張りの `sleep` が出力の
    /// パイプを握り続け、読み手(ディスパッチャの中継)の EOF が毎回最大 2 秒遅れる(実測 2.04 秒)
    static let script = """
        p=$1; shift
        "$@" & c=$!
        ( while kill -0 $c 2>/dev/null; do
            sleep \(pollSeconds)
            [ "$(ps -o ppid= -p $$ | tr -d ' ')" = "$p" ] || { kill -TERM $c 2>/dev/null; exit 0; }
          done ) </dev/null >/dev/null 2>&1 &
        w=$!
        wait $c; s=$?
        kill $w 2>/dev/null
        exit $s
        """
}
