// iOS シミュレータのクラッシュレポート(.ips)要約。ホスト Mac が
// ~/Library/Logs/DiagnosticReports に書く。行1=ヘッダ JSON(bundleID 等)、
// 行2以降=ペイロード JSON(exception/termination)。フォーマットは新macOSの
// JSON形式(旧テキスト形式は非対応)。

import Foundation

public enum SimulatorCrashReport {
    /// header/payload どちらかが JSON として解釈できなければ nil(例外は投げない)。
    public static func summarize(headerLine: String, payload: String) -> (bundleID: String?, reason: String?)? {
        guard let headerData = headerLine.data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return nil
        }
        guard let payloadData = payload.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        let bundleID = header["bundleID"] as? String
        return (bundleID, extractReason(from: body))
    }

    private static func extractReason(from body: [String: Any]) -> String? {
        if let exception = body["exception"] as? [String: Any] {
            let parts = [exception["type"] as? String, exception["signal"] as? String].compactMap { $0 }
            if !parts.isEmpty { return oneLine(parts.joined(separator: " ")) }
        }
        if let termination = body["termination"] as? [String: Any] {
            let name = termination["name"] as? String ?? (termination["signal"] as? Int).map { "signal \($0)" }
            let parts = [termination["indicator"] as? String, name].compactMap { $0 }
            if !parts.isEmpty { return oneLine(parts.joined(separator: " ")) }
        }
        return nil
    }

    private static func oneLine(_ s: String) -> String? {
        let flattened = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }

    /// dir 内の直近クラッシュを新しい順に探し、bundleID が一致する最初の1件を返す。
    public static func findRecent(
        bundleID: String,
        within seconds: TimeInterval = 120,
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports"),
        now: Date = Date()
    ) -> (path: String, reason: String?)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let cutoff = now.addingTimeInterval(-seconds)
        let candidates = entries
            .filter { $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate, mtime >= cutoff else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(50) // DiagnosticReports が肥大化していても走査を打ち切るための上限

        for (url, _) in candidates {
            guard let (header, payload) = readHeaderAndPayload(url),
                  let summary = summarize(headerLine: header, payload: payload),
                  summary.bundleID == bundleID else { continue }
            return (url.path, summary.reason)
        }
        return nil
    }

    private static func readHeaderAndPayload(_ url: URL) -> (header: String, payload: String)? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8),
              let newline = content.firstIndex(of: "\n") else { return nil }
        return (String(content[content.startIndex..<newline]), String(content[content.index(after: newline)...]))
    }
}
