/// ステップ1つぶんの応答時間計測の記録(契約: docs/response-measurement.md §5・§8.3、結果 JSON は docs/results-json.md)。
/// **この版で値が入るのは** `busyBeforeAction` / `quietWaitMs` / `firstFrameMs` / `firstFrameMissing` / `readyMissing`(常に
/// `notMeasuredInThisVersion`)だけ。`reactionMs`(t1 は画面の差での確認が要る)と t2 の欄は常に nil。
/// 記録する入力は**ステップの最初の注入**(例: スクロール探索のスワイプがあれば、タップより先のそのスワイプ)
public struct ResponseMeasurementRecord: Codable, Sendable, Equatable {
    /// 操作の前から描画が止まらなかった(prepare の `quiet == false`)。true のとき `firstFrameMs` は出さない
    public var busyBeforeAction: Bool
    /// prepare が描画の停止を待った時間。prepare が失敗したら nil
    public var quietWaitMs: Int?
    /// 最初の注入から、最初に提示されたフレームまでの遅れ。`busyBeforeAction` のときは nil
    /// (その「最初のフレーム」は前の操作の描画の続きにすぎない)
    public var firstFrameMs: Int?
    /// `firstFrameMs` が nil の理由。値があるときは nil
    public var firstFrameMissing: FirstFrameMissing?
    public var reactionMs: Int?
    public var readyMs: Int?
    public var readyAfterObservationStartMs: Int?
    public var observationStartMs: Int?
    public var readyDecidedBy: String?
    public var readyMissing: String?

    /// t2 が無い理由のうち、この版で言える唯一の値
    public static let readyNotMeasured = "notMeasuredInThisVersion"

    public enum FirstFrameMissing: String, Codable, Sendable, Equatable {
        case busyBeforeAction
        /// ブリッジの reason(Android `/responseCollect`)と同じ綴り
        case noInjectedInput
        case noFrame
        case frameHistoryIncomplete
        case noSessionApp
        /// prepare / collect が投げた(未対応の 501 を含む)
        case bridgeError
    }

    public init(busyBeforeAction: Bool, quietWaitMs: Int?, firstFrameMs: Int?,
                firstFrameMissing: FirstFrameMissing?, reactionMs: Int? = nil, readyMs: Int? = nil,
                readyAfterObservationStartMs: Int? = nil, observationStartMs: Int? = nil,
                readyDecidedBy: String? = nil, readyMissing: String? = Self.readyNotMeasured) {
        self.busyBeforeAction = busyBeforeAction
        self.quietWaitMs = quietWaitMs
        self.firstFrameMs = firstFrameMs
        self.firstFrameMissing = firstFrameMissing
        self.reactionMs = reactionMs
        self.readyMs = readyMs
        self.readyAfterObservationStartMs = readyAfterObservationStartMs
        self.observationStartMs = observationStartMs
        self.readyDecidedBy = readyDecidedBy
        self.readyMissing = readyMissing
    }

    /// prepare / collect の結果から組む。
    /// - `busyBeforeAction` は「描画が止まらなかった」だけ。prepare が reason 付きで quiet=false を返した(= 判定できなかった。
    ///   例 noSessionApp)ときは busy にせず、その reason を `firstFrameMissing` にする
    /// - bridge の reason が未知の綴りなら `firstFrameMissing` は nil(言えないときは欄ごと省く。bridgeError 等の別の理由に丸めない)
    public static func make(prepare: ResponsePrepareResult?, collect: ResponseCollectResult?) -> ResponseMeasurementRecord {
        guard let prepare else {
            return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: nil,
                                             firstFrameMs: nil, firstFrameMissing: .bridgeError)
        }
        if let reason = prepare.reason {
            return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: prepare.waitedMs,
                                             firstFrameMs: nil, firstFrameMissing: FirstFrameMissing(rawValue: reason))
        }
        if !prepare.quiet {
            return ResponseMeasurementRecord(busyBeforeAction: true, quietWaitMs: prepare.waitedMs,
                                             firstFrameMs: nil, firstFrameMissing: .busyBeforeAction)
        }
        guard let collect else {
            return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: prepare.waitedMs,
                                             firstFrameMs: nil, firstFrameMissing: .bridgeError)
        }
        if let ms = collect.firstFrameDelayMs {
            return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: prepare.waitedMs,
                                             firstFrameMs: ms, firstFrameMissing: nil)
        }
        return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: prepare.waitedMs, firstFrameMs: nil,
                                         firstFrameMissing: collect.reason.flatMap(FirstFrameMissing.init(rawValue:)))
    }
}
