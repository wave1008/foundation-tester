// 再利用できない旧ブリッジ(同一デバイス・版違い・別アプリへの注入)を**どの手段で止めるか**の決定。
// 純粋関数(I/O なし)にしてあるのは、決定の分岐を単体テストで固定するため —— 手段を取り違えると
// 「止めた」と報告して止まっておらず、残骸がポートを掴んだまま次の注入と衝突する。

import Foundation

public enum StaleBridgeStop: Equatable {
    /// `.inapp` 記録あり → 記録の udid+bundleID を simctl terminate(in-app の正しい後始末)
    case terminateRecordedInApp
    /// `.pid` ファイルあり → XCUITest ランナーを停止(`BridgeLauncher.stopAndWait`)
    case stopRunner
    /// どちらの記録も無い → **ポートを LISTEN している実体**を `PortHolder` で特定して止める。
    /// 記録の無い in-app ブリッジ(別クローンの `.fleetest` が起動した・記録前に run が中断された)は
    /// ここでしか止められない。2026-08-23 まではこの形を `.pid` 経路へ流して
    /// 「the bridge is not running (no .fleetest/bridge.pid)」で止めそこね、旧ブリッジが
    /// 掴んだままのポートへ新しい注入が衝突していた(受け手報告の never joined)
    case stopPortHolder

    public static func decide(hasInAppRecord: Bool, hasPidFile: Bool) -> StaleBridgeStop {
        if hasInAppRecord { return .terminateRecordedInApp }
        if hasPidFile { return .stopRunner }
        return .stopPortHolder
    }
}
