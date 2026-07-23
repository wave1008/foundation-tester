// RecordingIndex.swift
// <runDir>/recordings/index.json の DTO と書き出し。拡張側(vscode-ftester)との契約なので
// フィールド名・ネストを変えない(optional 追加のみなら ProtocolVersion 不要。この形自体を
// 変える場合は拡張側の対応するパーサも合わせて直すこと):
//   { "schemaVersion": 1, "recordings": [ { "worker", "platform", "file",
//     "segments": [ { "startedAt"(ISO8601+ミリ秒), "durationMs" } ] } ] }

import Foundation

public struct RecordingIndexSegment: Codable, Sendable {
    public var startedAt: String
    public var durationMs: Int

    public init(startedAt: String, durationMs: Int) {
        self.startedAt = startedAt
        self.durationMs = durationMs
    }
}

public struct RecordingIndexEntry: Codable, Sendable {
    /// "<platform>:<デバイス論理名>"(RunOrchestrator.swift:204 の worker id 規則と同一)
    public var worker: String
    public var platform: String
    /// runDir 相対パス(例 "recordings/ios-iPhone-16.mp4")
    public var file: String
    public var segments: [RecordingIndexSegment]

    public init(worker: String, platform: String, file: String, segments: [RecordingIndexSegment]) {
        self.worker = worker
        self.platform = platform
        self.file = file
        self.segments = segments
    }
}

public struct RecordingIndex: Codable, Sendable {
    public var schemaVersion: Int
    public var recordings: [RecordingIndexEntry]

    public init(schemaVersion: Int = 1, recordings: [RecordingIndexEntry]) {
        self.schemaVersion = schemaVersion
        self.recordings = recordings
    }
}

public enum RecordingIndexIO {
    public static let directoryName = "recordings"
    public static let indexFileName = "index.json"

    /// runDir/recordings/index.json を書く。1 件も無ければ書かず、recordings/ が(他に何も
    /// 残さず)空なら消す(ファイナライズが全滅したケースで空ディレクトリだけ残さないため)
    public static func write(_ entries: [RecordingIndexEntry], runDir: URL) {
        let dir = runDir.appendingPathComponent(directoryName)
        guard !entries.isEmpty else {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        guard let data = try? encoder.encode(RecordingIndex(recordings: entries)) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(indexFileName), options: .atomic)
    }

    /// worker id("<platform>:<論理名>")→ ファイル名(英数字以外は '-')。
    /// 衝突(revive 後の再録画等)の一意化は呼び出し側(VideoRecordingCoordinator)が行う
    public static func sanitizedFileName(for worker: String) -> String {
        String(worker.map { ch -> Character in
            ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "-"
        })
    }
}
