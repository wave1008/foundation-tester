// ResponseMeasurement.swift
// 応答時間計測の iOS 側(POST /responsePrepare・/responseCollect・/responseObservation・/responseObservationStop)。
// 契約と意味は Android と同じ: Sources/FTCore/ResponseMeasurementWire.swift。同期相手は
// AndroidRunner/src/com/example/ftbridge/ResponseProbe.java・ResponseObserver.java・InputInjector.java。
//
// **時計**: 端末の時刻はすべて mach_absolute_time を mach_timebase_info で ns に直した値の ms(`nowMs`)。
// xctrace の time-info `mabs-epoch` と同じ時計なので、ホストは Instruments のトレースのフレーム時刻をこの値へ写せる
// (Android の uptimeMillis に当たる)。端末が眠っている間は進まない(mach_absolute_time の性質)。
// **最初のフレームまでの遅れ(`firstFrameDelayMs`)はここでは測らない**: iOS ではホストが Instruments のトレースから後で埋める。
// そのため collect は常に null を返す(推測値を入れない)。
//
// **スレッド**: 状態はすべて main スレッド専用でロックを持たない。HTTP ハンドラは BridgeHTTPServer.dispatchToMain で
// 全部 main 上を1本ずつ走り、観測のタイマーも main の RunLoop(.common)で撃たれる。
// ハンドラの処理中に XCTest が main の RunLoop を入れ子で回してタイマーが割り込みうるので、`requestDepth` と `reading` で撃たせない。
// いずれのハンドラも操作後の整定(settlePending・QuiescenceWait)を掛けない(待ちが計測を汚す)。

import Foundation
import XCTest
import Darwin

enum ResponseMeasurement {

    // MARK: - 時計

    /// mach_timebase_info は不変なので1回だけ取る(numer/denom = ticks→ns。Apple Silicon の実機は 125/3)
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// 端末時刻[ms]。ticks × numer は 64bit を溢れうるので 128bit の乗算で ns に直す(Double を通さない = 丸めの漂いが無い)
    static func nowMs() -> Int64 {
        let ticks = mach_absolute_time()
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let ns = UInt64(timebase.denom).dividingFullWidth((high, low)).quotient
        return Int64(ns / 1_000_000)
    }

    // MARK: - 上限

    /// responsePrepare の quietMs の許容範囲[ms]。0 以下は待たずに quiet と誤読するので下限を置く(Android と同じ値)
    static let quietRangeMs: ClosedRange<Int> = 50...5_000
    /// timeoutMs の許容範囲[ms]。上限はホストの HTTP 待ちの導出元(BridgeClient.responsePrepare)
    static let timeoutRangeMs: ClosedRange<Int> = 100...30_000
    /// observeMs の許容範囲[ms]。下限は木の読み1回(実機 iPhone SE3 で約 300ms)を1回は含める値、
    /// 上限 60s は MAX_READS / MAX_TREES の見積り(応答が数 MB)の前提(Android と同じ値)
    static let observeRangeMs: ClosedRange<Int> = 200...60_000

    /// 木を読むタイマーの間隔[s]。読みの間に最低限あける間隔であって実効の間隔ではない: 1回の読み(app.snapshot)は
    /// 実機 iPhone SE3 で約 300ms かかり、その間と HTTP リクエストの処理中は main が塞がるので、実効の間隔は「main が空いたとき」。
    /// Android の読めなかった回の待ち(50ms)と同じ値 —— 速く読める環境(Simulator)でも UI のスレッドを占有し続けない
    static let readIntervalSeconds: TimeInterval = 0.05
    /// 1観測の読み回数の上限。上限 observeMs = 60s ÷ タイマー 50ms = 1200 回が理論上の最大なので余裕を持たせた値。
    /// 1回の記録は約 50 バイト(JSON)なので 2000 回でも約 100KB。尽きたら truncated で申告する
    static let maxReads = 2_000
    /// 変化した木の保存数の上限。1本は既定の要素上限(BridgeAPI.maxSnapshotElements = 120)で約 30KB と見積もり、
    /// 100 本で応答は約 3MB(Android と同じ値。LAN の実機でも転送できる範囲)。尽きたら truncated で申告する(ホストは observationTruncated)
    static let maxTrees = 100

    // MARK: - 状態(main 専用)

    final class Obs {
        let firstDown: Int64
        let capMs: Int64
        /// 上限の起点 = このステップの直近の注入。記録し直し(onLaterInjection)で進む
        var capBase: Int64
        var lastDown: Int64 = -1
        var injections = 0
        var endedAt: Int64 = -1
        var endReason: String?
        var closed = false
        var truncated = false
        /// 上限(capMs)に達して読みを止めている。観測は閉じない(同じステップの次の注入で再開できる)。cappedAt = 達した時刻
        var capped = false
        var cappedAt: Int64 = -1
        var reads: [ResponseObservation.Read] = []
        var trees: [ResponseObservation.Tree] = []
        /// 直前に保存した木のエンコード(変化の判定用)
        var lastTreeData: Data?

        init(firstDown: Int64, capMs: Int64) {
            self.firstDown = firstDown
            self.capMs = capMs
            self.capBase = firstDown
        }
    }

    /// 処理中の HTTP リクエストの数(BridgeRouter.handle が出入りで増減)。0 でなければ読みを撃たない
    static var requestDepth = 0
    private static var reading = false
    private static var running: Obs?
    /// 締めた観測を最初の注入の時刻で引けるよう直近 maxClosed 件だけ持つ(古い側から捨てる)。1件だと、ホストが取りに来る前に
    /// 次のステップの締めで上書きされうる。ホストは締まった観測を次のステップの注入の前に取るので、2件あれば取りこぼさない
    static let maxClosed = 2
    private static var closedObs: [Obs] = []
    private static var pendingCapMs: Int64 = 0
    private static var timer: Timer?
    /// 木を読むのに使うルーター(prepare で受け取る。ルーターは1つで寿命がプロセスと同じ)
    static weak var router: BridgeRouter?

    /// 注入の記録(armFirstDown 相当)。{最初・最後の時刻, 回数}。次の arm まで残す(collect と観測が後から読む)
    private static var armed = false
    private static var firstInjection: Int64 = -1
    private static var lastInjection: Int64 = -1
    private static var injectionCount = 0

    // MARK: - 注入の記録

    /// **合成する入力の直前**に呼ぶ(タップ・スワイプ・ドラッグ・ピンチ・長押し・キー入力。呼び元は Runner/ の各合成箇所)。
    /// 構えていないときは何もしない。最初の1回: 実行中の観測を締めて新しい観測を始める /
    /// 2回目以降: 観測の記録をこの注入から取り直し、上限の起点もここへ移す(Android の onLaterDown と同じ。
    /// 判定は最後の注入より後の読みしか使わないので、捨てた分は要らない)
    static func noteInjection() {
        guard armed else { return }
        let now = nowMs()
        lastInjection = now
        injectionCount += 1
        if firstInjection < 0 {
            firstInjection = now
            if let current = running { close(current, reason: "nextInjection", at: now) }
            running = Obs(firstDown: now, capMs: pendingCapMs)
            startTimer()
        } else if let obs = running, !obs.closed, obs.firstDown == firstInjection {
            obs.lastDown = now
            obs.injections = injectionCount
            obs.capBase = now
            obs.reads.removeAll()
            obs.trees.removeAll()
            obs.lastTreeData = nil
            obs.truncated = false
            obs.capped = false
            obs.cappedAt = -1
        }
    }

    /// 締める直前に、記録が同じ arm のままなら最後の注入・回数を観測へ写す(別の arm に替わっていたら写さない)
    private static func refreshStats(_ obs: Obs) {
        guard obs.firstDown == firstInjection else { return }
        obs.lastDown = lastInjection
        obs.injections = injectionCount
    }

    /// 上限に達していたら理由は cap・締めた時刻は達した時刻(読みはそこで止まっている。Android の close と同じ)
    private static func close(_ obs: Obs, reason: String, at time: Int64) {
        refreshStats(obs)
        var reason = reason
        var time = time
        // 期限(capBase + capMs)を過ぎてから締めるなら、検知が遅れただけで上限には達していた
        _ = markCappedIfReached(obs, at: time)
        if obs.capped {
            reason = "cap"
            time = obs.cappedAt
        }
        obs.closed = true
        obs.endReason = reason
        obs.endedAt = time
        if running === obs { running = nil }
        closedObs.append(obs)
        if closedObs.count > maxClosed { closedObs.removeFirst(closedObs.count - maxClosed) }
        if running == nil { stopTimer() }
    }

    // MARK: - 観測の読み

    private static func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: readIntervalSeconds, repeats: true) { _ in tick() }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func tick() {
        guard let obs = running, !obs.closed else { stopTimer(); return }
        guard !reading else { return }
        // 上限の判定は状態を書くだけで XCTest に触れないので、リクエスト処理中の割り込みでも安全(達した時刻を遅らせない)
        let t0 = nowMs()
        if markCappedIfReached(obs, at: t0) { return }
        guard requestDepth == 0, let router else { return }
        // 打ち切り・上限の後は木を読まない(同じステップの次の注入での記録し直しか締めを待つだけ)
        if obs.truncated || obs.capped { return }
        reading = true
        defer { reading = false }
        var snapshot: SnapshotResponse?
        // 前面にいないアプリの snapshot は XCTest を Tear Down させうる(appOrientation と同じ注意)ので、読まずに失敗の読みとして残す
        if let app = router.app, app.state == .runningForeground {
            _ = FTCatchObjCException {
                snapshot = try? router.observationSnapshot(app)
            }
        }
        append(to: obs, startMs: t0, endMs: nowMs(), snapshot: snapshot)
    }

    /// 上限に達していたら capped を立てて true(観測は閉じない)。達した後は何度呼んでも cappedAt を動かさない
    private static func markCappedIfReached(_ obs: Obs, at time: Int64) -> Bool {
        if obs.capped { return true }
        if time - obs.capBase > obs.capMs {
            obs.capped = true
            obs.cappedAt = obs.capBase + obs.capMs // 検知の時刻ではなく期限
            return true
        }
        return false
    }

    /// ホストの `GET /snapshot` が取った木も観測の読みとして残す。**iOS ではこれが読みの主な出どころ**: ステップの合間はホストが
    /// 検証・次のステップの解決のために木を取りに来てメインスレッドが空かず、タイマーの読みはほとんど入らない(iPhone SE3 で
    /// 1 ステップあたり 0〜1 回)。木はどの経路で取っても同じ画面の事実なので、判定の材料として同じに扱ってよい
    static func recordHostRead(_ snapshot: SnapshotResponse, startMs: Int64, endMs: Int64) {
        guard let obs = running, !obs.closed, !obs.truncated else { return }
        if markCappedIfReached(obs, at: startMs) { return }
        append(to: obs, startMs: startMs, endMs: endMs, snapshot: snapshot)
    }

    /// 読みを1件足す(記録し直しより前に始まった読みは捨てる)。木は前の木と変わったときだけ残す
    private static func append(to obs: Obs, startMs t0: Int64, endMs t1: Int64, snapshot: SnapshotResponse?) {
        if t0 < obs.capBase { return }
        // 期限をまたいだ・期限の後に終わった読みは入れない(Android の readLoop と同じ)
        if markCappedIfReached(obs, at: t1) { return }
        if !obs.truncated && obs.reads.count >= maxReads { obs.truncated = true }
        if !obs.truncated {
            var changed: (SnapshotResponse, Data)?
            if let snapshot, let data = Self.encodeForComparison(snapshot), data != obs.lastTreeData {
                changed = (snapshot, data)
            }
            if changed != nil && obs.trees.count >= maxTrees {
                // 変わった木を置けない読みは足さない: 足すと判定が前の木をその読みへ持ち越し、古い木で「2回連続で保持」と誤る
                obs.truncated = true
            } else {
                let index = obs.reads.count
                obs.reads.append(.init(startMs: Int(t0), endMs: Int(t1), ok: snapshot != nil))
                if let (snapshot, data) = changed {
                    obs.trees.append(.init(readIndex: index, snapshot: snapshot))
                    obs.lastTreeData = data
                }
            }
        }
    }

    /// 前の木との同一判定用。キー順を固定して辞書欄(truncatedTiers)の順序揺れで「変わった」と誤判定しない
    private static func encodeForComparison(_ snapshot: SnapshotResponse) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    // MARK: - エンドポイントの本体

    static func prepare(observeMs: Int, wait: () -> ResponsePrepareResult) -> ResponsePrepareResult {
        // 実行中の観測の最後の注入・回数は arm で消えるので、先に写す
        if let obs = running { refreshStats(obs) }
        pendingCapMs = Int64(observeMs)
        // 待つ間も、待ち終わっても(タイムアウトでも noScreenshot でも)必ず構える: 構えないと collect が前の操作の記録を拾う
        defer {
            armed = true
            firstInjection = -1
            lastInjection = -1
            injectionCount = 0
        }
        return wait()
    }

    static func collect() -> ResponseCollectResult {
        let first = firstInjection
        armed = false
        guard first >= 0 else {
            return ResponseCollectResult(downTimeMs: nil, firstFrameDelayMs: nil, reason: "noInjectedInput")
        }
        return ResponseCollectResult(downTimeMs: Int(first), firstFrameDelayMs: nil, reason: nil,
                                     lastDownTimeMs: Int(lastInjection), injections: injectionCount)
    }

    static func fetch(firstDownTimeMs: Int) -> ResponseObservation {
        guard let obs = closedObs.first(where: { Int($0.firstDown) == firstDownTimeMs }) else {
            return ResponseObservation(found: false)
        }
        return ResponseObservation(found: true, firstDownTimeMs: Int(obs.firstDown),
                                   lastDownTimeMs: obs.lastDown < 0 ? nil : Int(obs.lastDown),
                                   injections: obs.injections, endedAtMs: Int(obs.endedAt),
                                   endReason: obs.endReason, reads: obs.reads, trees: obs.trees,
                                   truncated: obs.truncated)
    }

    /// シナリオの終わり: 実行中を締め、それ以外の記録は捨てる(締めた1件だけ残す。Android の stopAll と同じ)。
    /// 注入の記録も解く(解かないと stop の後の普通の操作が新しい観測を始める)
    static func stopAll() {
        closedObs.removeAll()
        if let obs = running { close(obs, reason: "stopped", at: nowMs()) }
        running = nil
        armed = false
        firstInjection = -1
        lastInjection = -1
        injectionCount = 0
        stopTimer()
    }
}

extension BridgeRouter {

    /// 観測用の1回の読み。GET /snapshot と同じ形だが、**refFrames / refElements を更新しない**(操作が使う ref の表を
    /// 観測が書き換えない)・整定待ち(captureSettled)と焦点の申告(ライブクエリ)を省く。要素上限は既定
    func observationSnapshot(_ app: XCUIApplication) throws -> SnapshotResponse {
        snapshotElementLimit = BridgeAPI.maxSnapshotElements
        let cap = try captureOnce(app)
        return snapshotResponse(cap, elements: cap.elements)
    }

    /// POST /responsePrepare。画面の画素が quietMs の間変わらなくなるまで(最長 timeoutMs)待ち、次の最初の注入の記録を構える。
    /// 画素の比較は handleWaitForSettle と同じ settleFrame(撮影 + 内側の切り出し + バイト比較)
    func handleResponsePrepare(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(ResponsePrepareRequest.self, body)
        guard req.quietMs > 0, req.timeoutMs > 0, req.observeMs > 0 else {
            throw BridgeError(400, "quietMs, timeoutMs and observeMs must be positive integers")
        }
        let quietMs = req.quietMs.clamped(to: ResponseMeasurement.quietRangeMs)
        let timeoutMs = req.timeoutMs.clamped(to: ResponseMeasurement.timeoutRangeMs)
        let observeMs = req.observeMs.clamped(to: ResponseMeasurement.observeRangeMs)
        ResponseMeasurement.router = self
        let result = ResponseMeasurement.prepare(observeMs: observeMs) {
            waitForQuietScreen(quietMs: quietMs, timeoutMs: timeoutMs)
        }
        return .json(result)
    }

    /// 静止 = 「直前の絵と違った最後の撮影」から quietMs 経過。上限は最初の撮影ではなく呼び出しの入口から数える
    /// (Android の prepare と同じ: 待った時間 = 入口から)。画面が2枚以上の端末は撮れない(settleFrame が空を返す = 常に「静止」)ので
    /// 判定せず quiet = false / noScreenshot で返す
    private func waitForQuietScreen(quietMs: Int, timeoutMs: Int) -> ResponsePrepareResult {
        if DisplayRouting.isMultiDisplay {
            return ResponsePrepareResult(quiet: false, waitedMs: 0, reason: "noScreenshot")
        }
        let quietSeconds = Double(quietMs) / 1000
        let timeoutSeconds = Double(timeoutMs) / 1000
        let start = ProcessInfo.processInfo.systemUptime
        var latest: Data?
        var lastChangeAt = start
        while true {
            let frame = autoreleasepool { settleFrame(region: nil) }   // 1 周ごとに画像を作るので区切る
            let now = ProcessInfo.processInfo.systemUptime
            if frame.bytes != latest {
                latest = frame.bytes
                lastChangeAt = now
            }
            let waitedMs = Int(((now - start) * 1000).rounded())
            if now - lastChangeAt >= quietSeconds {
                return ResponsePrepareResult(quiet: true, waitedMs: waitedMs)
            }
            if now - start >= timeoutSeconds {
                return ResponsePrepareResult(quiet: false, waitedMs: waitedMs)
            }
        }
    }

    func handleResponseCollect() -> BridgeHTTPServer.Response {
        .json(ResponseMeasurement.collect())
    }

    func handleResponseObservation(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(ResponseObservationRequest.self, body)
        return .json(ResponseMeasurement.fetch(firstDownTimeMs: req.firstDownTimeMs))
    }

    func handleResponseObservationStop() -> BridgeHTTPServer.Response {
        ResponseMeasurement.stopAll()
        return .json(StoppedResponse(stopped: true))
    }

    private struct StoppedResponse: Encodable { let stopped: Bool }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
