// run の「準備中」の間の端末ごとの供給の段階(docs/design.md §18.1)。
// 供給側(BridgeProvisioner / ProfileWorkerFactory / AndroidLaneRecovery)が `report` で知らせ、
// 台帳の3つの書き手(入口の writeProgress・ProfileRunOrchestrator.writePreparingProgress・RunProgressState)が
// `snapshot()` を record の supply に載せる。段階の語彙は `RunProgressSupply.Step` の1箇所だけ。

import Foundation

/// 台帳 `~/.fleetest/runs/<pid>.json` の supply の1行。
/// 端末に属さない共有の段階(ランナーの build-for-testing)は name が空文字
public struct RunProgressSupply: Codable, Equatable, Sendable {
    public enum Step: String, Sendable {
        case runnerBuild
        case booting
        case bridge
        case installing
        case ready
    }

    /// `devices[].name`(`RunProgressLane.name` と同じ名前空間)。runnerBuild は空文字
    public let name: String
    /// "ios" / "android"
    public let platform: String?
    /// `Step.rawValue`。読み手は未知の値も落とさず運ぶ
    public let step: String

    public init(name: String, platform: String?, step: String) {
        self.name = name
        self.platform = platform
        self.step = step
    }

    public init(name: String, platform: String?, step: Step) {
        self.init(name: name, platform: platform, step: step.rawValue)
    }
}

/// 供給側から段階を知らせる口。step nil = その行を消す(runnerBuild の終了・供給に失敗した端末)
public typealias SupplyStageReporter = @Sendable (_ name: String, _ platform: String, _ step: RunProgressSupply.Step?) -> Void

public final class RunSupplyProgress: Sendable {
    /// 共有の段階(runnerBuild)の行の name
    public static let sharedName = ""

    private let rows = LockedValue<[String: RunProgressSupply]>([:])
    /// 今の書き手(owner)と通知先。書き手は入口 → 準備中 → RunProgressState と引き継がれる
    private let changeHandler = LockedValue<(owner: ObjectIdentifier, handler: @Sendable () -> Void)?>(nil)

    public init() {}

    /// 変更のたびに呼ぶ(同じ内容への書き込みでは呼ばない)。**ロックの外で呼ぶ** —— 呼び先は台帳を書き直して
    /// snapshot() を読む。後から登録した書き手が通知を引き継ぐ
    public func setOnChange(owner: ObjectIdentifier, _ handler: @escaping @Sendable () -> Void) {
        changeHandler.withLock { $0 = (owner, handler) }
    }

    /// **自分が今の書き手のときだけ**外す(先に退いた書き手の後片付けが、引き継いだ書き手の通知を消さない)
    public func releaseOnChange(owner: ObjectIdentifier) {
        changeHandler.withLock { if $0?.owner == owner { $0 = nil } }
    }

    public func set(name: String, platform: String?, step: RunProgressSupply.Step) {
        let row = RunProgressSupply(name: name, platform: platform, step: step)
        let changed = rows.withLock { rows -> Bool in
            guard rows[name] != row else { return false }
            rows[name] = row
            return true
        }
        if changed { notify() }
    }

    public func clear(name: String) {
        let changed = rows.withLock { $0.removeValue(forKey: name) != nil }
        if changed { notify() }
    }

    public func clearRunnerBuild() { clear(name: Self.sharedName) }

    /// 名前順(共有の段階の空文字が先頭)。順序が決まっていないと同じ内容でも record が毎回違って書き直される
    public func snapshot() -> [RunProgressSupply] {
        rows.withLock { $0.values.sorted { $0.name < $1.name } }
    }

    public var reporter: SupplyStageReporter {
        { [self] name, platform, step in
            if let step {
                set(name: name, platform: platform, step: step)
            } else {
                clear(name: name)
            }
        }
    }

    private func notify() {
        let handler = changeHandler.withLock { $0?.handler }
        handler?()
    }
}
