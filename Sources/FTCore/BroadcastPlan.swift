// BroadcastPlan.swift
// `ftester run --each-device`(ブロードキャスト実行)の分配計画。RunOrchestrator が
// 「platform 別の共有キュー」の代わりに「レーン(デバイス)別のキュー」を作るための純粋関数。
// 供給・インストール・フック・スタッガ・復帰・レポートは通常 run と同じ経路を通す(変えるのは
// キューの切り方だけ。RunOrchestrator.run の dispatch 分岐参照)。

import Foundation

/// RunOrchestrator.run のシナリオ分配の仕方
public enum ScenarioDispatch: Sendable {
    /// platform 別の共有キューから各ワーカーが早い者勝ちで取る(各シナリオは1台で1回)
    case shared
    /// 各レーンが同じセットを1回ずつ回す(`ftester run --each-device`)。lanes = 回るべき
    /// デバイス。**レーンとワーカーの突き合わせは `BroadcastPlan.laneKey(of:)`**(論理名)
    case broadcast(lanes: [BroadcastLane])
}

/// ブロードキャストの1レーン = 実行プロファイルの1デバイス
public struct BroadcastLane: Hashable, Sendable {
    /// `RunWorker.logicalName`(プロファイルのデバイス名)と一致させる
    public let key: String
    public let platform: String

    public init(key: String, platform: String) {
        self.key = key
        self.platform = platform
    }
}

public struct BroadcastPlan: Sendable {
    /// レーン key → そのレーンが回す item(`lane` を刻印済み。順序は入力のまま = LPT の
    /// 並びがレーン内でそのまま効く)。**0本のレーンは載せない**(キューを作ってもワーカーを
    /// 温めるだけで何もしない)
    public let queues: [String: [ScenarioRunItem]]
    /// 宣言 platform がどのレーンにも無い item(shared の「担当ワーカーなし」と同じ扱い)
    public let unassigned: [ScenarioRunItem]
    /// (シナリオ × レーン)の総数 = この run が回す本数
    public var total: Int { queues.values.reduce(0) { $0 + $1.count } }

    /// - items: 実行する順に並んだシナリオ。**platform 未指定(nil)は全レーンへ配る**
    ///   (shared は既定 platform の1台でしか走らせないが、ブロードキャストの目的は
    ///   「全デバイスがそれぞれ準備される」ことなので、OS を問わないシナリオは全台に要る)。
    ///   明示 platform はその platform のレーンだけ
    /// - lanes: 同じ key が2つ以上あれば先勝ち(レーン = デバイス論理名で一意のはず。
    ///   重ねると同じキューを2ワーカーが取り合い、片方の台に走らない本が出る)
    public static func make(items: [ScenarioRunItem], lanes: [BroadcastLane]) -> BroadcastPlan {
        var seen = Set<String>()
        let uniqueLanes = lanes.filter { seen.insert($0.key).inserted }
        let lanePlatforms = Set(uniqueLanes.map(\.platform))
        var queues: [String: [ScenarioRunItem]] = [:]
        var unassigned: [ScenarioRunItem] = []
        for item in items {
            if let platform = item.info.platform, !lanePlatforms.contains(platform) {
                unassigned.append(item)
                continue
            }
            for lane in uniqueLanes where item.info.platform == nil || item.info.platform == lane.platform {
                queues[lane.key, default: []].append(ScenarioRunItem(info: item.info, lane: lane.key))
            }
        }
        return BroadcastPlan(queues: queues, unassigned: unassigned)
    }

    /// ワーカーがどのレーンのぶんを回すか。プロファイル経路は `logicalName`(復帰で label =
    /// ポートが変わっても同じ台は同じ key に戻る)。非プロファイル経路(--ports)は label
    public static func laneKey(of worker: RunWorker) -> String {
        worker.logicalName ?? worker.label
    }
}
