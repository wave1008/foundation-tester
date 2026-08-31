// PipeLinePump.swift
// 子プロセスのパイプの行読み(FleetRunner.runEntry / ApiRunMachineFanout.runChild)。
// 同期版は RemoteRunDispatcher.runInheritedWithLineRewrite(警告が無いので寄せていない)。

import Foundation

/// パイプを専用スレッドでブロッキング読みし、行ごとに onLine を読み取りスレッド上で同期に呼ぶ。
/// 不変条件: splitter は読み取りスレッドだけが触り、flush は EOF(drain の完了)後だけ。
/// EOF は書込端が全部閉じたとき = 子だけでなく孫がパイプを継承して生きていれば来ない
/// (呼び出し側の従来挙動と同じ)。
public final class PipeLinePump: @unchecked Sendable {
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let splitter = StreamLineSplitter()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init(handle: FileHandle, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.onLine = onLine
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// 読み取りスレッドを起動する(1回だけ)。**捕捉は self のみ**にする ——
    /// splitter/handle を個別に捕捉すると非 Sendable な型がクロージャ境界を直接越えて警告になる
    /// (self は @unchecked Sendable なのでこれ越しなら越えられる)
    public func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                // availableData = 届いた分だけ返す(readData(ofLength:) は EOF まで貯める。2026-08-18 実測)
                let chunk = handle.availableData
                if chunk.isEmpty { break }   // 子の終了による書込端クローズで EOF
                for line in splitter.feed(chunk) { onLine(line) }
            }
            continuation.finish()
        }
    }

    /// EOF まで待ち、改行の無い末尾行があれば返す(呼び出し側がそれを onLine と同じ宛先へ流す)。
    /// **1回だけ**(AsyncStream は一度しか走査できない)
    public func drain() async -> String? {
        for await _ in stream {}
        return splitter.flush()
    }
}
