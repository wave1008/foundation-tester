// ブリッジ HTTP の内訳計測(FT_HTTP_TIMING=1 のときだけ有効)。
//
// なぜ要るか: ステップの actionMs は「ホストが呼んでから返るまで」しか持たず、ブリッジ側の
// ハンドラ計時と食い違ったときに差の所在(接続確立か・要求送信か・応答待ちか)が出ない。
// 実例: Android の /tap がホスト 5.5s・ブリッジのハンドラ 0.3s(2026-08-02)。
//
// URLSessionTaskMetrics の各日時は「取れないことがある」(接続再利用時は connect 系が nil)。
// nil を 0 と混同しないよう、欠けた区間は "-" で出す。

import Foundation

/// FT_HTTP_TIMING=1 のときだけ生成される。閾値(既定 1000ms)を超えたリクエストのみ stderr へ出す
/// (全件出すと 8 レーンで数千行になり、生ログが実行ログを埋める)。
final class HTTPTimingCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared: HTTPTimingCollector? = {
        guard ProcessInfo.processInfo.environment["FT_HTTP_TIMING"] == "1" else { return nil }
        let thresholdMs = Double(ProcessInfo.processInfo.environment["FT_HTTP_TIMING_MS"] ?? "") ?? 1000
        return HTTPTimingCollector(thresholdMs: thresholdMs)
    }()

    private let thresholdMs: Double

    init(thresholdMs: Double) {
        self.thresholdMs = thresholdMs
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let tx = metrics.transactionMetrics.last else { return }
        let totalMs = metrics.taskInterval.duration * 1000
        guard totalMs >= thresholdMs else { return }
        func gap(_ from: Date?, _ to: Date?) -> String {
            guard let from, let to else { return "-" }
            return String(format: "%.0f", to.timeIntervalSince(from) * 1000)
        }
        let path: String = task.originalRequest?.url?.path ?? "?"
        // fetchStart→connectEnd = 接続確立(Android は adb forward 越し・応答ごとに切断される)
        // requestEnd→responseStart = 送信完了〜最初のバイト(= ブリッジが accept して処理し終えるまで)
        var parts: [String] = ["[ftester] httpTiming \(path)"]
        parts.append("total=" + String(format: "%.0f", totalMs))
        parts.append("queue=" + gap(metrics.taskInterval.start, tx.fetchStartDate))
        parts.append("connect=" + gap(tx.connectStartDate, tx.connectEndDate))
        parts.append("send=" + gap(tx.requestStartDate, tx.requestEndDate))
        parts.append("ttfb=" + gap(tx.requestEndDate, tx.responseStartDate))
        parts.append("recv=" + gap(tx.responseStartDate, tx.responseEndDate))
        parts.append("reused=\(tx.isReusedConnection)")
        let line: String = parts.joined(separator: " ") + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
