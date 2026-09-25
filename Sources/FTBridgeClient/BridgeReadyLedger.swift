// xcuitest ランナーが一度でも ready(/status が ready:true)になったことの記録
// (`.fleetest/bridge-<port>.ready`)。
//
// **要る理由**: 「起動しきれないランナーを止める」掃除(StaleLedgerSweep.sweepStuckStartingRunners)は
// 生存時間(elapsed)とログの mtime(quietFor)だけで「まだ起動中か」を推測していたが、
// どちらも**一度readyになった後の長寿ブリッジ**では腐る —— elapsed は ready 後も伸び続けるだけで
// 「起動中」の意味を失い、quietFor は xcodebuild の出力がブロックバッファされるため、
// リクエストの合間は無音のまま「起動側も諦めた」と読める形になる。ready 印は
// waitUntilReady() の成功時に一度だけ書く**事実**なので、この2つと違って時間が経っても腐らない。
//
// 書くのは BridgeLauncher.waitUntilReady() の成功パスだけ。消すのは StaleLedgerSweep が
// 他の台帳(.pid/.toolchain 等)と同じ「そのポートのランナーが生きているか」の1点で判定する
// (`.pid`/`.inapp` を実体で掃除する既存の規律と揃える。プロセスの終了経路が複数あるため、
// stop() 側の個別の削除には頼らない)。

import Foundation

public enum BridgeReadyLedger {
    static func url(stateDir: URL, port: UInt16) -> URL {
        stateDir.appendingPathComponent("bridge-\(port).ready")
    }

    /// ベストエフォート(書けなくても sweepStuckStartingRunners が connectProbe/lease の
    /// 判定へ倒れるだけで、誤って何かを壊すことはない)
    public static func mark(stateDir: URL, port: UInt16) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url(stateDir: stateDir, port: port).path, contents: nil)
    }

    public static func exists(stateDir: URL, port: UInt16) -> Bool {
        FileManager.default.fileExists(atPath: url(stateDir: stateDir, port: port).path)
    }

    public static func remove(stateDir: URL, port: UInt16) {
        try? FileManager.default.removeItem(at: url(stateDir: stateDir, port: port))
    }
}
