// 「出力は無いが止まってはいない」長さの決まった待ちを子→親へ申告する(ScenarioHost の idle 打ち切りの許容を
// その待ちの上限ぶん延ばす)。対象は待ちの長さを利用者が書けるもの: canSelect 系(ifCanSelect / repeatWhileCanSelect)
// の waitSeconds・httpRequest・doUntilTrue。**DeadlineExclusion と違い締め切り(FTSync・scenarioTimeout)からは
// 差し引かない** —— 外部やアプリを待つ時間はシナリオの時間。長さの分からない素の Swift(procedure の中など)は申告しない。
// 入れ子(doUntilTrue の中の ifCanSelect)は親が積んで最大を採る(ScenarioIdleWatch)

import Foundation
import Synchronization

public enum IdleAllowance {
    public enum Change: Sendable {
        case began(capMs: Int)
        case ended
    }

    /// FTDriveCore が emit(ScenarioEvent kind "idleAllowance")へ橋渡しする。ScenarioHost が横取りして emit に渡さない
    public static var observer: (@Sendable (Change) -> Void)? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    private static let state = Mutex<(@Sendable (Change) -> Void)?>(nil)

    /// `seconds` が 0 以下・非有限なら申告しない(待たない待ちで無出力を延ばさない)
    public static func during<T>(seconds: Double, _ body: () throws -> T) rethrows -> T {
        guard seconds > 0, seconds.isFinite, let observer else { return try body() }
        observer(.began(capMs: Int((seconds * 1000).rounded(.up))))
        defer { observer(.ended) }
        return try body()
    }
}
