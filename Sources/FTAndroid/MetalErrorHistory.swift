// AndroidHealthProbe が計測した Metal エラー行数(metalErrorCount)の時系列を NDJSON で
// 蓄積する。閾値(metalErrorWarnThreshold)調整・劣化速度分析用。書き込みは observeIssues
// からのみ(呼び出し頻度契約は AndroidHealthProbe.swift 側のコメント参照)。

import FTCore
import Foundation

public enum MetalErrorHistory {
    /// このファイルが 5MB を超えたら .1 へロールオーバーする閾値。
    /// AndroidHealthProbe.metalErrorLogSizeCap と同値だが対象ファイルが別なので独立定義。
    static let rotationCapBytes = 5_000_000

    private static let lock = NSLock()
    /// serial ごとの直近記録 count。カウントはブート内で単調増加するため、前回と同値なら
    /// 書かなくても変化点の記録だけで全履歴(いつ・どの値まで増えたか)を忠実に再構成できる。
    private static var lastRecorded: [String: Int] = [:]

    static var defaultFile: URL {
        EmulatorLog.directory.appendingPathComponent("metal-history.ndjson")
    }

    private struct HistoryLine: Encodable {
        let ts: String
        let avd: String
        let serial: String
        let count: Int
    }

    /// count が変化した(直近記録値と異なる)ときだけ1行追記する。同一プロセス内の並行呼び出し
    /// (observeIssues は serial ごとに withTaskGroup で並行実行される)に備え、直近値の比較から
    /// ファイル追記まで1つの NSLock で直列化する。
    public static func record(avdID: String, serial: String, count: Int, at: Date = Date(),
                              file: URL? = nil) {
        let target = file ?? defaultFile
        lock.lock()
        defer { lock.unlock() }
        if lastRecorded[serial] == count { return }
        lastRecorded[serial] = count
        // metalErrorCount のログサイズ超過センチネル(Int.max)は妥当な JSON 数値ではないため
        // -1 に変換して記録する(count フィールドを常に有効な数値に保つため)
        let recordedCount = count == Int.max ? -1 : count
        guard let line = encode(HistoryLine(
            ts: ISO8601DateFormatter().string(from: at), avd: avdID, serial: serial,
            count: recordedCount)) else { return }
        appendLine(line, to: target)
    }

    /// テスト専用: in-memory の直近値辞書をクリアする。本体コード(observeIssues 等)からは
    /// 呼ばないこと(呼ぶと「変化時のみ記録」の判定基準が失われる)。
    public static func _resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        lastRecorded.removeAll()
    }

    private static func encode(_ line: HistoryLine) -> String? {
        guard let data = try? JSONEncoder().encode(line) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func appendLine(_ line: String, to file: URL) {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rotateIfNeeded(file: file)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func rotateIfNeeded(file: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size > rotationCapBytes else { return }
        let rotated = file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: file, to: rotated)
    }
}
