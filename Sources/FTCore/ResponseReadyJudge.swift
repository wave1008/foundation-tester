// t2(操作可能)の判定。ブリッジが記録した木の履歴(ステップ j の最初の注入から次の計測ステップ i の最初の注入まで)を、
// i が実際に解決して操作した対象で判定する(docs/response-measurement.md §5「2b の方式」)。
// ドライバに触らない純粋な関数だけを持つ。解決・遮蔽の判定は呼び手が StepExecutor と同じ共有の判定で組んで渡す
// (ここで二重に持たない)。

import Foundation

/// t2 が無い理由(`ResponseMeasurementRecord.readyMissing` の生の値)
public enum ResponseReadyMissing: String, Codable, Sendable, Equatable {
    /// 条件が揃う前に次の操作が撃たれた(履歴が `nextInjection` で締まり、揃った回が無い)
    case notReadyBeforeNextAction
    /// 上限(observeMs)で締まり、揃った回が無い
    case observationTimeout
    /// 記録の上限に達して途中から記録をやめ、それまでに揃った回が無い
    case observationTruncated
    /// ブリッジに観測が無かった
    case observationLost
    /// 次のステップに、セレクタで解決した要素が無い(座標の操作等)
    case noTarget
    /// 観測の取得が投げた
    case bridgeError
}

/// ステップ j の t2 の確定。次の計測ステップ i が対象を解決した時点で作り、j のレコードへ当てる
public struct ResponseReadyUpdate: Codable, Sendable, Equatable {
    public var readyMs: Int?
    public var readyAfterLastInjectionMs: Int?
    public var injectionSpanMs: Int?
    public var injections: Int?
    public var readyDecidedBy: String?
    public var readyIdentity: String?
    public var readyMissing: String?
    /// 観測で読めた木の回数(最後の注入より後・読めた回だけ)。t2 の分解能と、判定の材料がどれだけあったかを示す事実。
    /// 観測が見つからなかった・取れなかったときは nil
    public var observedReads: Int?

    public init(readyMs: Int? = nil, readyAfterLastInjectionMs: Int? = nil, injectionSpanMs: Int? = nil,
                injections: Int? = nil, readyDecidedBy: String? = nil, readyIdentity: String? = nil,
                readyMissing: String? = nil, observedReads: Int? = nil) {
        self.observedReads = observedReads
        self.readyMs = readyMs
        self.readyAfterLastInjectionMs = readyAfterLastInjectionMs
        self.injectionSpanMs = injectionSpanMs
        self.injections = injections
        self.readyDecidedBy = readyDecidedBy
        self.readyIdentity = readyIdentity
        self.readyMissing = readyMissing
    }
}

/// ステップ j の注入の事実(`ResponseCollectResult` から)
public struct ResponseInjectionFacts: Sendable, Equatable {
    public var firstDownTimeMs: Int
    public var lastDownTimeMs: Int
    public var injections: Int
    public init(firstDownTimeMs: Int, lastDownTimeMs: Int, injections: Int) {
        self.firstDownTimeMs = firstDownTimeMs
        self.lastDownTimeMs = lastDownTimeMs
        self.injections = injections
    }
}

public enum ResponseReadyJudge {
    /// 値が出ない更新。注入の事実(回数・最初から最後まで)は collect 由来で言えるので載せる
    public static func missing(_ reason: ResponseReadyMissing, facts: ResponseInjectionFacts) -> ResponseReadyUpdate {
        ResponseReadyUpdate(injectionSpanMs: facts.lastDownTimeMs - facts.firstDownTimeMs,
                            injections: facts.injections, readyMissing: reason.rawValue)
    }

    /// - resolve: 次のステップ i のセレクタを StepExecutor と同じ解決で木に当てる
    /// - isOccluded: 解決した要素の中心が別の要素に覆われているか(タップ前と同じ共有の判定)
    /// - usedFrame: i が実際に解決して操作した要素の枠
    ///
    /// 条件(§5 の ①②③): 解決でき・有効・覆われておらず・枠が i の使った枠と等しい。
    /// 1回の読みだけで揃っても確定しない(次の成功した読みでも揃うことを要る)。
    /// ④(画素の静止)は判定しない・要素の同一性は比べない(`readyIdentity` = locator)
    public static func judge(observation: ResponseObservation, facts: ResponseInjectionFacts,
                             resolve: (SnapshotResponse) -> ElementInfo?,
                             isOccluded: (ElementInfo, SnapshotResponse) -> Bool,
                             usedFrame: FTRect) -> ResponseReadyUpdate {
        guard observation.found else { return missing(.observationLost, facts: facts) }
        let reads = observation.reads ?? []
        let trees = (observation.trees ?? []).sorted { $0.readIndex < $1.readIndex }

        func holds(readIndex: Int) -> Bool {
            guard let tree = trees.last(where: { $0.readIndex <= readIndex }) else { return false }
            let snapshot = tree.snapshot
            guard let element = resolve(snapshot), element.enabled,
                  element.frame == usedFrame, !isOccluded(element, snapshot) else { return false }
            return true
        }

        let candidates = reads.indices.filter { reads[$0].ok && reads[$0].startMs >= facts.lastDownTimeMs }
        let observed = candidates.count
        for (position, readIndex) in candidates.enumerated() {
            guard position + 1 < candidates.count else { break }
            guard holds(readIndex: readIndex), holds(readIndex: candidates[position + 1]) else { continue }
            let t2 = reads[readIndex].endMs
            return ResponseReadyUpdate(
                readyMs: t2 - facts.firstDownTimeMs,
                readyAfterLastInjectionMs: t2 - facts.lastDownTimeMs,
                injectionSpanMs: facts.lastDownTimeMs - facts.firstDownTimeMs,
                injections: facts.injections, readyDecidedBy: "tree", readyIdentity: "locator",
                observedReads: observed)
        }

        var result: ResponseReadyUpdate
        if observation.truncated == true {
            result = missing(.observationTruncated, facts: facts)
        } else {
            switch observation.endReason {
            case "nextInjection": result = missing(.notReadyBeforeNextAction, facts: facts)
            case "cap": result = missing(.observationTimeout, facts: facts)
            default:
                // stopped など: 理由を言えないので readyMissing を省く(丸めない)
                result = ResponseReadyUpdate(injectionSpanMs: facts.lastDownTimeMs - facts.firstDownTimeMs,
                                             injections: facts.injections)
            }
        }
        result.observedReads = observed
        return result
    }
}
