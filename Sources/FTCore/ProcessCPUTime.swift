// このプロセスが実際に貰えた CPU 時間(user+sys)。
//
// **用途は締め切りの妥当性の判断**(2026-09-10): ステップの上限は壁時計(FTSync.commandTimeout)で
// 測っているが、ホストが飽和していると壁時計だけが進み、ステップは仕事をしていないのに打ち切られる。
// 壁時計と並べて CPU 時間を記録すると「飽和で進めなかった」と「相手が固まっていた」を分けられる。
//
// **単独ではハングを検出できない** —— I/O 待ち(ブリッジの応答待ち)も CPU 0 なので、
// 「固まっている」と「健全に待っている」が区別できない。進捗の尺度と組み合わせて読むこと。

import Foundation

public enum ProcessCPUTime {
    /// プロセス開始からの user+sys を合算したミリ秒。取得できなければ nil
    /// (Linux/macOS とも getrusage は失敗しない想定だが、失敗を 0 と混ぜない)
    public static func milliseconds() -> Int? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
        let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
        return Int((user + system).rounded())
    }

    /// 2点間の増分(どちらかが nil なら nil = 不明。0 に丸めない)
    public static func delta(from start: Int?, to end: Int?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, end - start)
    }
}
