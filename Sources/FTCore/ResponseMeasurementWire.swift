// レスポンス計測のブリッジ契約(Android の POST /responsePrepare・/responseCollect。同期相手は
// AndroidRunner/src/com/example/ftbridge/BridgeRouter.java の handleResponsePrepare / handleResponseCollect)。
// **BridgeDTO.swift に置かない**: あちらは iOS のブリッジ(in-app dylib・XCUITest ランナー)にも組み込まれ、
// 触ると iOS のブリッジの版上げを要求される(BridgeContractTests)。この契約は Android だけ

/// `POST /responsePrepare`(Android v102〜)。アプリのフレームが `quietMs` の間出なくなるまで(最長 `timeoutMs`)待ち、
/// 次に注入する最初の ACTION_DOWN の記録を構える
public struct ResponsePrepareRequest: Codable, Sendable, Equatable {
    public var quietMs: Int
    public var timeoutMs: Int
    public init(quietMs: Int, timeoutMs: Int) {
        self.quietMs = quietMs
        self.timeoutMs = timeoutMs
    }
}

public struct ResponsePrepareResult: Codable, Sendable, Equatable {
    /// true = 描画が止まっていた / false = 上限まで描画が続いた、または判定できなかった(reason)
    public var quiet: Bool
    public var waitedMs: Int
    public var reason: String?
    public init(quiet: Bool, waitedMs: Int, reason: String? = nil) {
        self.quiet = quiet
        self.waitedMs = waitedMs
        self.reason = reason
    }
}

/// `POST /responseCollect` の応答。ブリッジは null を明示で返す(キーは常にある)
public struct ResponseCollectResult: Codable, Sendable, Equatable {
    /// 記録した ACTION_DOWN の downTime(端末の uptimeMillis)。注入が無ければ nil
    public var downTimeMs: Int?
    /// downTime の後に最初に提示されたフレームまでの遅れ(ms)。測れなければ nil
    public var firstFrameDelayMs: Int?
    public var reason: String?
    public init(downTimeMs: Int?, firstFrameDelayMs: Int?, reason: String? = nil) {
        self.downTimeMs = downTimeMs
        self.firstFrameDelayMs = firstFrameDelayMs
        self.reason = reason
    }
}
