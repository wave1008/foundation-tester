/// ステップ1つぶんの応答時間計測の記録(契約: docs/response-measurement.md §5・§8.3、結果 JSON は docs/results-json.md)。
/// 操作の直後に入るのは `busyBeforeAction` / `quietWaitMs` / `firstFrameMs` / `firstFrameMissing` だけ。t2 の欄は
/// このステップの次の計測ステップが対象を解決した時点で `ResponseReadyUpdate` として後から入る
/// (次の計測ステップが無い = シナリオの最後の計測ステップ・途中で終わったシナリオは判定されず、t2 の欄は nil のまま)。
/// `reactionMs`(t1 は画面の差での確認が要る)は常に nil。
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
    /// 最後の注入から操作可能まで / 最初の注入から最後の注入まで / 注入の回数(`readyMs` と `firstFrameMs` は最初の注入から)
    public var readyAfterLastInjectionMs: Int?
    public var injectionSpanMs: Int?
    public var injections: Int?
    /// `locator` = 同じ指定で解決した要素までしか照合していない(要素の同一性は比べない)
    public var readyIdentity: String?

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
                readyDecidedBy: String? = nil, readyMissing: String? = nil,
                readyAfterLastInjectionMs: Int? = nil, injectionSpanMs: Int? = nil, injections: Int? = nil,
                readyIdentity: String? = nil) {
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
        self.readyAfterLastInjectionMs = readyAfterLastInjectionMs
        self.injectionSpanMs = injectionSpanMs
        self.injections = injections
        self.readyIdentity = readyIdentity
    }

    /// 後から来た t2 の確定を当てる(欄ごとに上書き。更新が持たない欄は元のまま)
    public func applying(_ update: ResponseReadyUpdate) -> ResponseMeasurementRecord {
        var copy = self
        copy.readyMs = update.readyMs
        copy.readyAfterLastInjectionMs = update.readyAfterLastInjectionMs
        copy.injectionSpanMs = update.injectionSpanMs
        copy.injections = update.injections
        copy.readyDecidedBy = update.readyDecidedBy
        copy.readyIdentity = update.readyIdentity
        copy.readyMissing = update.readyMissing
        return copy
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
        let injections = collect.injections > 0 ? collect.injections : nil
        if let ms = collect.firstFrameDelayMs {
            return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: prepare.waitedMs,
                                             firstFrameMs: ms, firstFrameMissing: nil, injections: injections)
        }
        return ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: prepare.waitedMs, firstFrameMs: nil,
                                         firstFrameMissing: collect.reason.flatMap(FirstFrameMissing.init(rawValue:)),
                                         injections: injections)
    }
}
