// iOS 実機の最初のフレーム(`firstFrameMs`)を、ホストが録った xctrace の記録から結果へ後から入れる純粋な部分。
// 契約: docs/response-measurement.md §5・§8.5。XCUITest ランナーは `downTimeMs`(端末の mach 時刻を ms にした値)だけを返し、
// `firstFrameMs` は nil のまま。ここで `displayed-surfaces-interval` の時刻(同じ端末の時計)と突き合わせて埋める。
// 事実だけを書く: 記録が覆っていない注入には何も入れない(推測で `noFrame` にしない)。

import Foundation

public enum ResponseTracePatch {

    /// `time-info` の値。`ns = ticks × numer / denom`(`mach_timebase_info` と同じ式)
    public struct TimeInfo: Equatable, Sendable {
        /// 記録の開始時点の端末の mach_absolute_time
        public var mabsEpochTicks: UInt64
        public var numer: UInt64
        public var denom: UInt64
        public init(mabsEpochTicks: UInt64, numer: UInt64, denom: UInt64) {
            self.mabsEpochTicks = mabsEpochTicks
            self.numer = numer
            self.denom = denom
        }
    }

    /// 記録が覆う端末時計の範囲(ms)。両端を含む
    public struct Coverage: Equatable, Sendable {
        public var startMs: Double
        public var endMs: Double
        public init(startMs: Double, endMs: Double) {
            self.startMs = startMs
            self.endMs = endMs
        }
        func contains(_ ms: Double) -> Bool { ms >= startMs && ms <= endMs }
    }

    // MARK: 時刻の換算

    /// mach の ticks → ns。`ticks × numer` は Int64 を超えうる(ticks は端末の稼働時間に比例し、24MHz・数か月で 10^14 台、
    /// numer=125 で 10^16 台 = 余裕は 2 桁足らず)ので、**先に denom で割って余りを別に掛ける**:
    /// `(ticks / denom) × numer + (ticks % denom) × numer / denom`(厳密で、結果自体が Int64 を超えるとき以外は溢れない。
    /// 余りの項は `denom × numer` 未満)。溢れる・denom が 0 のときは nil
    public static func nanoseconds(ticks: UInt64, numer: UInt64, denom: UInt64) -> Int64? {
        guard denom > 0 else { return nil }
        let (high, overflowMul) = (ticks / denom).multipliedReportingOverflow(by: numer)
        guard !overflowMul else { return nil }
        let (remainderPart, overflowRem) = (ticks % denom).multipliedReportingOverflow(by: numer)
        guard !overflowRem else { return nil }
        let (sum, overflowAdd) = high.addingReportingOverflow(remainderPart / denom)
        guard !overflowAdd, sum <= UInt64(Int64.max) else { return nil }
        return Int64(sum)
    }

    /// `time-info` の表から換算の材料を取る。行のどれかに `mabs-epoch` と `timebase-info`(`numer/denom`)があれば採る。
    /// 値は本文(raw)を先に、読めなければ表示用(fmt)を見る
    public static func timeInfo(from table: XctraceTable) -> TimeInfo? {
        for row in table.rows {
            guard let epochCell = row["mabs-epoch"], let baseCell = row["timebase-info"] else { continue }
            guard let ticks = [epochCell.raw, epochCell.fmt].compactMap({ $0 }).lazy.compactMap({ UInt64($0) }).first,
                  let (numer, denom) = [baseCell.raw, baseCell.fmt].compactMap({ $0 }).lazy
                      .compactMap(parseTimebase).first else { continue }
            return TimeInfo(mabsEpochTicks: ticks, numer: numer, denom: denom)
        }
        return nil
    }

    static func parseTimebase(_ text: String) -> (UInt64, UInt64)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numer = UInt64(parts[0].trimmingCharacters(in: .whitespaces)),
              let denom = UInt64(parts[1].trimmingCharacters(in: .whitespaces)),
              numer > 0, denom > 0 else { return nil }
        return (numer, denom)
    }

    /// 記録の開始からの ns(`start` 列の本文)→ 端末時計の ms。ns は Int64 で足してから ms にする(Double へ落とすのは最後の1回だけ)
    static func deviceMs(epochNanoseconds: Int64, offsetNanoseconds: Int64) -> Double? {
        let (sum, overflow) = epochNanoseconds.addingReportingOverflow(offsetNanoseconds)
        return overflow ? nil : Double(sum) / 1_000_000
    }

    /// `displayed-surfaces-interval` の各行の提示時刻(端末時計の ms・昇順)。`start` が読めない行は飛ばす。
    /// `end` は記録の覆う範囲の代用(行の `start + duration` の最大。duration 列が無ければ start)
    public static func surfaces(timeInfo: TimeInfo, table: XctraceTable)
        -> (times: [Double], lastEndMs: Double?) {
        guard let epochNs = nanoseconds(ticks: timeInfo.mabsEpochTicks, numer: timeInfo.numer,
                                        denom: timeInfo.denom) else { return ([], nil) }
        var times: [Double] = []
        var lastEnd: Double?
        for row in table.rows {
            guard let startNs = row["start"].flatMap({ Int64($0.raw) }),
                  let ms = deviceMs(epochNanoseconds: epochNs, offsetNanoseconds: startNs) else { continue }
            times.append(ms)
            let durationNs = row["duration"].flatMap { Int64($0.raw) } ?? 0
            let (endOffset, endOverflow) = startNs.addingReportingOverflow(max(durationNs, 0))
            let end = deviceMs(epochNanoseconds: epochNs, offsetNanoseconds: endOverflow ? startNs : endOffset) ?? ms
            lastEnd = max(lastEnd ?? end, end)
        }
        return (times.sorted(), lastEnd)
    }

    /// 記録の覆う範囲。終わりは**表の最後のフレームの終わり**(`--toc` の記録の長さの方が短ければそちら)。記録の長さの終わりまで
    /// 覆うとは言わない —— 記録の終わり際の描画が表に入らないことがあり(iPhone SE3・E2E-RN の run の最後のステップで、他の回は
    /// 約 250 ms で出るタブ切り替えが `noFrame` になった)、その区間で `noFrame` と言うと誤る。最後のフレームの後のステップは
    /// 範囲の外 = 何も入れない側に倒れる(言えないときは欄ごと省く)
    public static func coverage(timeInfo: TimeInfo, durationSeconds: Double?, lastSurfaceEndMs: Double?) -> Coverage? {
        guard let epochNs = nanoseconds(ticks: timeInfo.mabsEpochTicks, numer: timeInfo.numer, denom: timeInfo.denom)
        else { return nil }
        let start = Double(epochNs) / 1_000_000
        guard let lastSurfaceEndMs else { return nil }
        let recordedEnd = durationSeconds.map { start + $0 * 1000 }
        return Coverage(startMs: start, endMs: min(lastSurfaceEndMs, recordedEnd ?? lastSurfaceEndMs))
    }

    // MARK: 結果への当て込み

    /// `sortedSurfaceMs`(昇順)で `downTimeMs` より**厳密に後**の最初の提示。同時刻は後ではない
    /// (注入と同じ瞬間の提示は、注入に応えたものと言えない)
    static func firstSurface(after downMs: Double, in sortedSurfaceMs: [Double]) -> Double? {
        var low = 0
        var high = sortedSurfaceMs.count
        while low < high {
            let mid = (low + high) / 2
            if sortedSurfaceMs[mid] > downMs { high = mid } else { low = mid + 1 }
        }
        return low < sortedSurfaceMs.count ? sortedSurfaceMs[low] : nil
    }

    /// 当て込めるステップか: 注入の時刻があり、まだ最初のフレームも欠けた理由も無く、操作の前に描画が止まっていた
    static func isPatchable(_ response: ResponseMeasurementRecord) -> Bool {
        response.downTimeMs != nil && response.firstFrameMs == nil
            && response.firstFrameMissing == nil && !response.busyBeforeAction
    }

    /// 1本の記録へ当てる。`changed` = 書き換えたステップ数(0 なら呼び手はファイルを書き直さない)、
    /// `outside` = 注入の時刻、または探す範囲の終わりが記録の範囲の外だったステップ数(何も入れない)、
    /// `unbounded` = 観測の締まった時刻(`observationEndMs`)が無く探す範囲を言えないステップ数(何も入れない)。
    /// 探す範囲は「注入より後・観測が締まった時刻まで(その時刻を含む)」。次のシナリオのフレームを自分のものにしない
    public static func apply(surfaceMs: [Double], coverage: Coverage, to record: ScenarioRunRecord)
        -> (record: ScenarioRunRecord, changed: Int, outside: Int, unbounded: Int) {
        guard var timeline = record.timeline else { return (record, 0, 0, 0) }
        var changed = 0
        var outside = 0
        var unbounded = 0
        for index in timeline.indices {
            guard var response = timeline[index].response, isPatchable(response),
                  let down = response.downTimeMs.map(Double.init) else { continue }
            guard coverage.contains(down) else {
                outside += 1
                continue
            }
            guard let end = response.observationEndMs.map(Double.init) else {
                unbounded += 1
                continue
            }
            if let surface = firstSurface(after: down, in: surfaceMs), surface <= end {
                response.firstFrameMs = Int((surface - down).rounded())
            } else if coverage.contains(end) {
                response.firstFrameMissing = .noFrame
            } else {
                outside += 1
                continue
            }
            timeline[index].response = response
            changed += 1
        }
        guard changed > 0 else { return (record, 0, outside, unbounded) }
        var patched = record
        patched.timeline = timeline
        return (patched, changed, outside, unbounded)
    }
}
