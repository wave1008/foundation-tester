// レスポンス計測のブリッジ契約(POST /responsePrepare・/responseCollect・/responseObservation・
// /responseObservationStop)。**Android ブリッジと iOS の XCUITest ランナーが共有する**(in-app は持たない)。
// 同期相手: AndroidRunner/src/com/example/ftbridge/BridgeRouter.java の handleResponse* と ResponseProbe.java /
// ResponseObserver.java、Runner/FleetestRunnerUITests/ResponseMeasurement.swift。
// **ここを変えたら Android(VERSION_CODE / expectedBridgeVersionCode)と iOS(BridgeDTO.bridgeProtocolVersion)の
// 両方の版を上げる**(Runner/project.yml と BridgeSourceSet.xcuitest に載るので、触ると iOS の指紋も動く)。
// 時刻の単位は ms。時計はブリッジごとに違う: Android = SystemClock.uptimeMillis(MotionEvent.downTime と同じ)/
// iOS = mach_absolute_time を mach_timebase_info で ns に直して ms にした値(xctrace の time-info `mabs-epoch` と同じ時計)

/// `POST /responsePrepare`。アプリのフレームが `quietMs` の間出なくなるまで(最長 `timeoutMs`)待ち、
/// 次に注入する最初の ACTION_DOWN の記録を構える。`observeMs` = その注入を起点に木を読み続ける上限(t2 の観測。v104〜)
public struct ResponsePrepareRequest: Codable, Sendable, Equatable {
    public var quietMs: Int
    public var timeoutMs: Int
    public var observeMs: Int
    public init(quietMs: Int, timeoutMs: Int, observeMs: Int) {
        self.quietMs = quietMs
        self.timeoutMs = timeoutMs
        self.observeMs = observeMs
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
    /// 記録した最初の ACTION_DOWN の downTime(端末の uptimeMillis)。注入が無ければ nil。
    /// t2 の観測の ID を兼ねる(`ResponseObservationRequest.firstDownTimeMs`)
    public var downTimeMs: Int?
    /// downTime の後に最初に提示されたフレームまでの遅れ(ms)。測れなければ nil
    public var firstFrameDelayMs: Int?
    public var reason: String?
    /// このステップで最後に記録した ACTION_DOWN の downTime と、DOWN の回数(1つのステップが複数回注入することがある。v104〜)
    public var lastDownTimeMs: Int?
    public var injections: Int
    public init(downTimeMs: Int?, firstFrameDelayMs: Int?, reason: String? = nil,
                lastDownTimeMs: Int? = nil, injections: Int = 0) {
        self.downTimeMs = downTimeMs
        self.firstFrameDelayMs = firstFrameDelayMs
        self.reason = reason
        self.lastDownTimeMs = lastDownTimeMs
        self.injections = injections
    }
}

/// `POST /responseObservation`: 最初の注入の downTime で観測を指して、締め終わった観測の記録を受け取る(v104〜)。
/// 観測は「次に計測するステップの最初の注入」か上限(`observeMs`)で締まる。締まっていない観測・知らない ID は `found = false`
public struct ResponseObservationRequest: Codable, Sendable, Equatable {
    public var firstDownTimeMs: Int
    public init(firstDownTimeMs: Int) { self.firstDownTimeMs = firstDownTimeMs }
}

/// 1回の観測の記録。時刻はどれも端末の uptimeMillis
public struct ResponseObservation: Codable, Sendable {
    public var found: Bool
    public var firstDownTimeMs: Int?
    /// 観測したステップの最後の DOWN と回数(締めた時点の値)
    public var lastDownTimeMs: Int?
    public var injections: Int?
    /// 締めた時刻と理由: `nextInjection`(次に計測するステップの最初の注入)/ `cap`(observeMs に達した)/
    /// `stopped`(/responseObservationStop)
    public var endedAtMs: Int?
    public var endReason: String?
    /// 木を読んだ全回(古い順)。`ok == false` は読めなかった回(根が取れない等)
    public var reads: [Read]?
    /// 木が前の読みから変わった回だけの中身(`readIndex` は `reads` の添字)。最初の読みは必ず入る
    public var trees: [Tree]?
    /// 記録の上限(読みの回数・木の数)に達して途中から記録をやめた
    public var truncated: Bool?
    /// Android だけ(v107〜): 取得の時点で SurfaceFlinger を読み、最初の注入から締めた時刻(`endedAtMs`)までに出た最初のフレームの遅れ。
    /// collect の時点ではまだ出ていなかった遅いフレームを拾うため(collect の `noFrame` は確定ではない)。
    /// 出ていなければ nil で `firstFrameReason` = `noFrame`、履歴が足りなければ `frameHistoryIncomplete`。iOS は nil(Instruments の記録で決める)
    public var firstFrameDelayMs: Int?
    public var firstFrameReason: String?

    public struct Read: Codable, Sendable, Equatable {
        public var startMs: Int
        public var endMs: Int
        public var ok: Bool
        public init(startMs: Int, endMs: Int, ok: Bool) {
            self.startMs = startMs
            self.endMs = endMs
            self.ok = ok
        }
    }

    /// SnapshotResponse が Equatable でないので Equatable にしない
    public struct Tree: Codable, Sendable {
        public var readIndex: Int
        /// GET /snapshot と同じ形
        public var snapshot: SnapshotResponse
        public init(readIndex: Int, snapshot: SnapshotResponse) {
            self.readIndex = readIndex
            self.snapshot = snapshot
        }
    }

    public init(found: Bool, firstDownTimeMs: Int? = nil, lastDownTimeMs: Int? = nil, injections: Int? = nil,
                endedAtMs: Int? = nil, endReason: String? = nil, reads: [Read]? = nil, trees: [Tree]? = nil,
                truncated: Bool? = nil, firstFrameDelayMs: Int? = nil, firstFrameReason: String? = nil) {
        self.firstFrameDelayMs = firstFrameDelayMs
        self.firstFrameReason = firstFrameReason
        self.found = found
        self.firstDownTimeMs = firstDownTimeMs
        self.lastDownTimeMs = lastDownTimeMs
        self.injections = injections
        self.endedAtMs = endedAtMs
        self.endReason = endReason
        self.reads = reads
        self.trees = trees
        self.truncated = truncated
    }
}
