// RecordingWallClock.swift
// 壁時計⇔録画位置の区分計算(AVFoundation 非依存の純粋関数)。
// contract: 拡張側(vscode-ftester/src/recordingsModel.ts)の offsetMsForWallClock と
// 同一規則で実装すること(スパン内は先行スパン合計+差分、欠落は次スパン先頭、
// 全区間より前/空は 0、全区間より後は総尺にclamp)。文言はそちらのコメントを踏襲。

import Foundation

enum RecordingWallClock {

    /// 壁時計 at のオフセット(ミリ秒)を segments 表(開始順)から計算する。
    /// 録画ソース(iOS: 単一 .mov / Android: セグメント連結)は欠落(録画停止していた区間)を
    /// 持たないため、この値がそのままソース内 CMTime 位置(ミリ秒)になる
    static func offsetMs(_ segments: [RecordingIndexSegment], at: Date) -> Int {
        guard !segments.isEmpty else { return 0 }
        var cumulative = 0
        for segment in segments {
            guard let start = ISO8601Millis.date(from: segment.startedAt) else {
                cumulative += segment.durationMs
                continue
            }
            let end = start.addingTimeInterval(Double(segment.durationMs) / 1000)
            if at < start { return cumulative }
            if at < end {
                return cumulative + Int((at.timeIntervalSince(start) * 1000).rounded())
            }
            cumulative += segment.durationMs
        }
        return cumulative
    }

    /// segments を壁時計範囲 range と交差させ、range に収まる部分だけを返す(境界でクリップ)。
    /// 交差がゼロ・startedAt 解析不能なセグメントは除外する。1シナリオのクリップに含まれる
    /// 「実録画区間」の一覧(index.json の segments)を作るのに使う
    static func intersect(_ segments: [RecordingIndexSegment],
                          range: (start: Date, end: Date)) -> [RecordingIndexSegment] {
        var result: [RecordingIndexSegment] = []
        for segment in segments {
            guard let segStart = ISO8601Millis.date(from: segment.startedAt) else { continue }
            let segEnd = segStart.addingTimeInterval(Double(segment.durationMs) / 1000)
            let clippedStart = max(segStart, range.start)
            let clippedEnd = min(segEnd, range.end)
            guard clippedEnd > clippedStart else { continue }
            let durationMs = Int((clippedEnd.timeIntervalSince(clippedStart) * 1000).rounded())
            guard durationMs > 0 else { continue }
            result.append(RecordingIndexSegment(
                startedAt: ISO8601Millis.string(from: clippedStart), durationMs: durationMs))
        }
        return result
    }

    /// segments(開始順)の全域を壁時計範囲として返す。空なら nil
    static func wallClockRange(of segments: [RecordingIndexSegment]) -> (start: Date, end: Date)? {
        guard let first = segments.first, let firstStart = ISO8601Millis.date(from: first.startedAt),
              let last = segments.last, let lastStart = ISO8601Millis.date(from: last.startedAt) else {
            return nil
        }
        return (firstStart, lastStart.addingTimeInterval(Double(last.durationMs) / 1000))
    }
}
