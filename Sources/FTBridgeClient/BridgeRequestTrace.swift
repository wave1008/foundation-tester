// FT_BRIDGE_TRACE=<id,id,...>: ブリッジへの要求を1件1行で stderr へ出す調査用の記録(既定は出さない)。
// シナリオのプロセスの stderr は実行ログ(results/runs/<月>/<runID>/events/<scenario>.ndjson の stream "stderr")に残るので、
// フレークの赤の回について「撃った操作の時刻と座標」と「撮った木の中の指定した要素の枠」を run の後から突き合わせられる
// (録画とランナーのログだけでは、撃つ前にツールが何を見たかが分からない)。値は記録する要素の id のカンマ区切り。
// 子プロセスへは環境がそのまま継がれる(ScenarioHost.childEnvironment)。行の形は `line` が唯一の定義元

import Foundation
import FTCore

enum BridgeRequestTrace {
    static let environmentKey = "FT_BRIDGE_TRACE"

    /// nil = 記録しない
    static let watchedIdentifiers: Set<String>? = parse(ProcessInfo.processInfo.environment[environmentKey])

    static func parse(_ raw: String?) -> Set<String>? {
        guard let raw else { return nil }
        let ids = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return ids.isEmpty ? nil : ids
    }

    /// 本文は先頭だけ(座標・ref が読めれば足りる。打鍵の本文を丸ごと残さない)
    static let bodyPrefixLength = 160

    /// 1行の JSON。`/snapshot` の応答からは指定した id の要素の枠だけを `[x, y, width, height]` で抜く
    static func line(method: String, path: String, query: String?, body: Data?, status: Int?,
                     started: Date, finished: Date, response: Data?, watched: Set<String>) -> String {
        var trace: [String: Any] = [
            "t": ISO8601Millis.string(from: started),
            "ms": Int((finished.timeIntervalSince(started) * 1000).rounded()),
            "req": method + " " + path + (query.map { "?" + $0 } ?? ""),
        ]
        if let status { trace["status"] = status }
        if let body, let text = String(data: body, encoding: .utf8) { trace["body"] = String(text.prefix(bodyPrefixLength)) }
        if path == "/snapshot", let response,
           let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let elements = root["elements"] as? [[String: Any]] {
            var frames: [String: [Double]] = [:]
            for element in elements {
                guard let id = element["identifier"] as? String, watched.contains(id),
                      let frame = element["frame"] as? [String: Any] else { continue }
                frames[id] = ["x", "y", "width", "height"].map { (frame[$0] as? NSNumber)?.doubleValue ?? .nan }
            }
            trace["frames"] = frames
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["bridgeTrace": trace], options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func emit(_ request: URLRequest, status: Int?, started: Date, response: Data?) {
        guard let watched = watchedIdentifiers else { return }
        let text = line(method: request.httpMethod ?? "GET", path: request.url?.path ?? "?", query: request.url?.query,
                        body: request.httpBody, status: status, started: started, finished: Date(),
                        response: response, watched: watched)
        guard !text.isEmpty else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
