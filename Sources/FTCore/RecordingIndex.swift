// RecordingIndex.swift
// <runDir>/recordings/index.json の DTO と書き出し。拡張側(vscode-fleetest)との契約。
// schemaVersion 2(v1 からの破壊的変更: エントリがワーカー単位→シナリオ単位。拡張側は
// schemaVersion===2 のみ受け付ける):
//   { "schemaVersion": 2, "recordings": [ { "scenarioID", "worker", "platform", "file",
//     "segments": [ { "startedAt"(ISO8601+ミリ秒), "durationMs" } ] } ],
//     "clipsAttempted", "clipsFailed", "encoderFallback" }
// 1 recordings[] エントリ = 1 シナリオ(テスト関数)のクリップ。segments はそのクリップに
// 含まれる実録画区間(壁時計。ワーカーの録画区間とシナリオ区間の交差。Android は複数になり得る)。
// clipsAttempted/clipsFailed/encoderFallback は run 全体の集計(optional。エンコーダ不調で
// 1本もクリップが取れなかった run も、recordings が空のまま clipsAttempted > 0 で書き出す
// = その run を拡張の録画タブから消さないため。vscode-fleetest/src/recordingsModel.ts と同期)。
// フィールド追加のみ(optional)なら ProtocolVersion 不要。この形自体を変える場合は
// 拡張側の対応するパーサも合わせて直すこと。

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
    /// クラス名.メソッド名(ScenarioInfo.id と同一)
    public var scenarioID: String
    /// "<platform>:<デバイス論理名>"(RunOrchestrator.swift:204 の worker id 規則と同一)
    public var worker: String
    public var platform: String
    /// runDir 相対パス(例 "recordings/クラス名-S0010.mp4")
    public var file: String
    public var segments: [RecordingIndexSegment]

    public init(scenarioID: String, worker: String, platform: String, file: String,
                segments: [RecordingIndexSegment]) {
        self.scenarioID = scenarioID
        self.worker = worker
        self.platform = platform
        self.file = file
        self.segments = segments
    }
}

public struct RecordingIndex: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var recordings: [RecordingIndexEntry]
    /// この run で切り出しを試みた interval 数(nil = 集計を渡さなかった呼び出し)
    public var clipsAttempted: Int?
    /// clipsAttempted のうち使えるクリップが得られなかった数
    public var clipsFailed: Int?
    /// この run 中にハードウェアエンコーダからソフトウェアエンコーダへ切り替えたか
    public var encoderFallback: Bool?

    public init(schemaVersion: Int = RecordingIndex.currentSchemaVersion,
                recordings: [RecordingIndexEntry],
                clipsAttempted: Int? = nil, clipsFailed: Int? = nil, encoderFallback: Bool? = nil) {
        self.schemaVersion = schemaVersion
        self.recordings = recordings
        self.clipsAttempted = clipsAttempted
        self.clipsFailed = clipsFailed
        self.encoderFallback = encoderFallback
    }
}

public enum RecordingIndexIO {
    public static let directoryName = "recordings"
    public static let indexFileName = "index.json"

    /// runDir/recordings/index.json を書く。entries が空でも clipsAttempted > 0 なら書く
    /// (切り出しを試みたが1本も取れなかった run を拡張の録画タブから消さないため)。
    /// 両方 0/空なら書かず、recordings/ が(他に何も残さず)空なら消す
    public static func write(_ entries: [RecordingIndexEntry], runDir: URL,
                             clipsAttempted: Int = 0, clipsFailed: Int = 0,
                             encoderFallback: Bool = false) {
        let dir = runDir.appendingPathComponent(directoryName)
        guard clipsAttempted > 0 || !entries.isEmpty else {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        let index = RecordingIndex(
            recordings: entries,
            clipsAttempted: clipsAttempted > 0 ? clipsAttempted : nil,
            clipsFailed: clipsAttempted > 0 ? clipsFailed : nil,
            encoderFallback: clipsAttempted > 0 ? encoderFallback : nil)
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(indexFileName), options: .atomic)
    }

    /// 任意の識別子(scenarioID・worker id 等)→ ファイル名(文字・数字以外は '-')。
    /// 日本語等の非 ASCII は保持する(scenarioID は大半が日本語。ASCII 限定だと全部 '-' に潰れて
    /// 判読不能・衝突しやすい実害があった。results/scenarios/*.json も日本語ファイル名の前例あり)。
    /// 衝突(同一 scenarioID の revive 後再実行等)の一意化は呼び出し側(VideoRecordingCoordinator)が行う
    public static func sanitizedFileName(for id: String) -> String {
        String(id.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        })
    }
}
