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
        lock.lock()
        defer { lock.unlock() }
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
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}
