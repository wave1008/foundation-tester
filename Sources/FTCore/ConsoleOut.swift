// ConsoleOut.swift
// プロセス内の全書き手が共有する、直列化された stdout/stderr の書き込み口。
//
// **stdout と stderr が同じロックを共有するのが要点**(片方だけ直列化しても効かない)。
// `fleetest run` の子(FleetRunner.runEntry)は stdout/stderr を1本の Pipe へ合流させる ——
// この構成では2つの fd が同じパイプを指すため、stdout 側だけロックしても stderr 側の
// 無防備な書き込みがいつでも割り込める。実害: `print()` は端末でない fd に対して
// ブロックバッファ(既定 4096 バイト)になり、巨大な1回の print(all.joined(...)) 呼び出しの
// 途中でバッファが溢れて複数回の write(2) に分割される。その分割の合間に別スレッド
// (VideoRecordingCoordinator 等)が `FileHandle.standardError.write` で無防備に割り込むと、
// 1行が2つの write に裂けて出力される(例: `exist "#row_01"` が `ex` と `ist "#row_01"` に分裂)。
// 対策は「バッファを介さず、1回の呼び出し分をロックの下で1本の byte 列として書き切る」ことに尽きる
// (FileHandle.write と違い、生の write(2) はブロックバッファを持たないのでロックの下にいる限り安全)。
import Foundation

public enum ConsoleOut {
    /// stdout 書き手と stderr 書き手が同じ1個のロックを取る(上記の理由により分けない)
    private static let lock = NSLock()

    /// **出力経路でブロックされた時間**(このプロセスの全書き手の合計。ミリ秒)。
    /// write(2) はブロッキングなので、読み手が詰まると**ロックを握ったまま返らない** ——
    /// そのとき止まるのは書こうとしたスレッドだけでなく、協調スレッドプールごと詰まって
    /// **全レーンが同時に固まる**。ステップの壁時計の締め切り(FTSync.commandTimeout)が
    /// この待ちに食われていないかを記録から判定するための計器(2026-09-10)。
    /// 読み手は `blockedMilliseconds` の差分を取る(cpuMs と同じ使い方)
    private static let meterLock = NSLock()
    private static var blockedMs = 0
    private static var longestBlockMs = 0

    /// プロセス開始からの累計。差分を取って「このステップの間に何ミリ秒ブロックされたか」を出す
    public static var blockedMilliseconds: Int {
        meterLock.lock(); defer { meterLock.unlock() }; return blockedMs
    }

    /// 1 回の書き込みが返るまでの最長。合計だけだと「細かい待ちが多い」と
    /// 「1 回で 100 秒詰まった」を区別できない
    public static var longestBlockMilliseconds: Int {
        meterLock.lock(); defer { meterLock.unlock() }; return longestBlockMs
    }

    private static func recordBlocked(_ duration: Duration) {
        let ms = Int(duration.components.seconds) * 1000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        meterLock.lock()
        blockedMs += ms
        longestBlockMs = max(longestBlockMs, ms)
        meterLock.unlock()
    }

    /// `print(text)` 相当。呼び出し側は末尾に改行を付けない(ここで1個だけ付与する)
    public static func out(_ text: String) {
        emit(text, fd: FileHandle.standardOutput.fileDescriptor)
    }

    /// `FileHandle.standardError.write` の直書きに代わる口。呼び出し側は末尾に改行を付けない
    public static func err(_ text: String) {
        emit(text, fd: FileHandle.standardError.fileDescriptor)
    }

    /// 既に自前の区切り(JSON-RPC の改行等)を持つバイト列を stdout へ。**改行を足さない**。
    /// 文字列の口と同じロックを共有するので、stderr の診断と混ざらない
    public static func out(_ data: Data) {
        emit(data, fd: FileHandle.standardOutput.fileDescriptor)
    }

    /// 改行を持たない stderr の出力(`\r` で同じ行を上書きする進捗表示等)。**改行を足さない**。
    /// 文字列の口と同じロックを共有する —— 進捗行だけロックの外に残すと、そこが裂ける
    public static func err(_ data: Data) {
        emit(data, fd: FileHandle.standardError.fileDescriptor)
    }

    /// 本体。fd を直接受け取る形にしてあるのはテスト用(ConsoleOutTests がパイプの
    /// 書き込み端 fd を渡して検証する。標準出力/標準エラーを差し替える必要が無い)。
    /// internal のままでよい(呼び出し側は out/err だけを使う)
    static func emit(_ text: String, fd: Int32) {
        emit(Data((text + "\n").utf8), fd: fd)
    }

    /// 本体(バイト列版)。改行の付与は文字列版が済ませている
    static func emit(_ data: Data, fd: Int32) {
        var data = data
        // **ロック待ちも計器に含める** —— 先客が write(2) で詰まっているときの待ちが
        // まさに測りたいもの(recordBlocked の doc)
        let clock = ContinuousClock()
        let start = clock.now
        lock.lock()
        defer { lock.unlock(); recordBlocked(clock.now - start) }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Foundation.write(fd, base.advanced(by: offset), buffer.count - offset)
                // 0<n<残量(短い write)はループで続きを書き切る —— ここを端折ると短い write が
                // 起きた瞬間に行が裂ける(このファイルが解決する当のバグと同じ形になる)。
                // **このループはテストで踏めない**: ブロッキングの fd への write(2) は全バイトを
                // 書くまで返らない(短く返るのはシグナル割り込みのときだけ)ので、パイプ越しの
                // 変異チェックでは生き残る(2026-09-07 に確認済み)。O_NONBLOCK な fd と
                // 割り込みのためだけに残す防御。**「テストが無いから消せる」と読まないこと**
                // **EINTR は諦める理由にならない**: fleetest は SIGINT/SIGTERM を扱うので
                // シグナルで中断された write を諦めると、同じ「行が裂ける」形が稀に再発する
                if n < 0 && errno == EINTR { continue }
                // **EAGAIN / ENOBUFS も諦めない**。諦めると書きかけの行の直後に次の行が続き、
                // NDJSON が2行ぶん壊れる(2026-09-19 実測: api monitor のフレーム2枚が1行に
                // 繋がった。errno は未記録のため EAGAIN か ENOBUFS かは未確定)。
                // 待つのはブロッキングの write(2) が本来待つのと同じ = 上限を置かない
                if n < 0 && (errno == EAGAIN || errno == ENOBUFS) {
                    awaitWritable(fd)
                    continue
                }
                guard n > 0 else {
                    let code = n < 0 ? errno : 0
                    giveUp(fd: fd, written: offset, total: buffer.count, errno: code)
                    return
                }
                offset += n
            }
        }
    }

    /// 再試行の刻み(ミリ秒)。EAGAIN は POLLOUT で起きるが、ENOBUFS は POLLOUT が立ったままでも
    /// 返り続けうる(ソケットでなくカーネルのバッファ不足)ので、poll が即座に返っても空回りしない
    /// ための下限。100ms は 2 秒周期のモニター・人が読むログのどちらにも見えない遅れ
    static let retryIntervalMilliseconds: Int32 = 100

    private static func awaitWritable(_ fd: Int32) {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let start = DispatchTime.now()
        _ = poll(&pfd, 1, retryIntervalMilliseconds)
        let waitedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let floorNs = UInt64(retryIntervalMilliseconds) * 1_000_000
        if waitedNs < floorNs { usleep(useconds_t((floorNs - waitedNs) / 1000)) }
    }

    /// 書き切れなかった。**書きかけの行は改行で閉じる**(次の行が前の行に繋がって2行とも
    /// 壊れるのを1行で止める)。理由は stderr へ生の write(2) で1行 —— emit はロックを握って
    /// いるので再入できない(NSLock は再帰しない)。stderr 自身の失敗なら何も言えない
    private static func giveUp(fd: Int32, written: Int, total: Int, errno code: Int32) {
        if written > 0 {
            var newline: UInt8 = 0x0A
            _ = Foundation.write(fd, &newline, 1)
        }
        guard fd != FileHandle.standardError.fileDescriptor else { return }
        let reason = code == 0 ? "write returned 0" : String(cString: strerror(code))
        let message = "[fleetest] output write gave up after \(written)/\(total) bytes"
            + " (fd \(fd), errno \(code): \(reason))\n"
        message.utf8CString.withUnsafeBufferPointer { buf in
            _ = Foundation.write(FileHandle.standardError.fileDescriptor, buf.baseAddress, buf.count - 1)
        }
    }
}
