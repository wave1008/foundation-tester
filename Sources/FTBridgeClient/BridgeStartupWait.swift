// XCUITest ランナーの起動待ちを「固定の締切」でなく「進み具合」で切る規則(純粋関数)。
//
// 再起動直後の xcodebuild(Xcode の初回ロード + 8 並列)は `Test Suite … started` まで実測 138 秒、
// HTTP が上がるのはさらに数十秒後で、固定 180 秒の締切だと**上がる直前に諦めて殺し、次の run が
// また冷えた状態から始める**(2026-09-14 に 2 プロファイル連続で local 8 台全滅。台帳 §19.25)。
// 締切を伸ばすのではなく、ログが伸びている(xcodebuild が仕事をしている)間は待つ。

import Foundation

public enum BridgeStartupWait {
    /// 起動ログに現れる「テスト本体が始まった」印。ここから先は HTTP が数秒で上がるので、
    /// 以後は進み具合で延ばさず、この時刻から `budget` だけ待つ
    public static let suiteStartedMarker = "Test Suite 'All tests' started"

    /// 待ち続けてよいか。
    /// - 印の前: 直近の進み(ログが伸びた時刻。無ければ起動時刻)から `budget` 以内なら待つ
    ///   = 何も伸びないまま `budget` を跨いだら諦める(固定締切と同じ厳しさを「無音」に対して保つ)
    /// - 印の後: 印の時刻から `budget` 以内だけ待つ(動いているのに答えないランナーを永久に待たない)
    public static func shouldKeepWaiting(now: Date, launchedAt: Date, lastProgressAt: Date?,
                                         suiteStartedAt: Date?, budget: TimeInterval) -> Bool {
        let anchor = suiteStartedAt ?? lastProgressAt ?? launchedAt
        return now < anchor.addingTimeInterval(budget)
    }
}
