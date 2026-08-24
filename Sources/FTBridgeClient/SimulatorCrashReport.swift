// iOS シミュレータのクラッシュレポート(.ips)要約。ホスト Mac が
// ~/Library/Logs/DiagnosticReports に書く。行1=ヘッダ JSON(bundleID 等)、
// 行2以降=ペイロード JSON(exception/termination)。新macOSの JSON形式を優先し、
// 解釈できなければ旧テキスト形式(Identifier:/Exception Type: 等の行)にフォールバックする。

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
        var parts: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            let fields = [exception["type"] as? String, exception["signal"] as? String].compactMap { $0 }
            if !fields.isEmpty { parts.append(fields.joined(separator: " ")) }
        }
        // dyld 由来の即死は exception が EXC_CRASH SIGABRT にしかならず、**何が読めなかったのか**は
        // termination.reasons にしか出ない(実害: シミュレータのランタイム共有キャッシュ破損で
        // "Library not loaded: libSystem.B.dylib / no dyld cache"。受け手報告 2026-08-24)
        if let dyld = dyldDetail(from: body) { parts.append(dyld) }
        if parts.isEmpty, let termination = body["termination"] as? [String: Any] {
            let name = termination["name"] as? String ?? (termination["signal"] as? Int).map { "signal \($0)" }
            let fields = [termination["indicator"] as? String, name].compactMap { $0 }
            if !fields.isEmpty { parts.append(fields.joined(separator: " ")) }
        }
        return parts.isEmpty ? nil : oneLine(parts.joined(separator: " / "))
    }

    /// termination が DYLD 名前空間か reasons を持つときだけ返す(通常のクラッシュでは nil =
    /// 既存の文言を変えない)。reasons は「読めなかった dylib」と「なぜ」が別の行に来るので2行まで
    private static func dyldDetail(from body: [String: Any]) -> String? {
        guard let termination = body["termination"] as? [String: Any] else { return nil }
        let namespace = termination["namespace"] as? String
        let reasons = (termination["reasons"] as? [String])?.filter { !$0.isEmpty } ?? []
        guard namespace == "DYLD" || !reasons.isEmpty else { return nil }
        let head = [namespace, termination["indicator"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        let detail = reasons.prefix(2).joined(separator: "; ")
        return [head, detail].filter { !$0.isEmpty }.joined(separator: ": ")
    }

    private static func oneLine(_ s: String) -> String? {
        let flattened = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }

    /// 旧テキスト形式 .ips 用フォールバック。「ラベル: 値」の行を素朴に走査する(正規表現不要)。
    public static func summarizeTextFormat(_ text: String) -> (bundleID: String?, reason: String?)? {
        var bundleID: String?
        var exceptionType: String?
        var terminationReason: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if bundleID == nil {
                bundleID = value(afterPrefix: "Identifier:", in: s)
            }
            if exceptionType == nil {
                exceptionType = value(afterPrefix: "Exception Type:", in: s)
            }
            if terminationReason == nil {
                terminationReason = value(afterPrefix: "Termination Reason:", in: s)
            }
        }
        let reasonParts = [exceptionType, terminationReason].compactMap { $0 }
        let reason = reasonParts.isEmpty ? nil : oneLine(reasonParts.joined(separator: " / "))
        guard bundleID != nil || reason != nil else { return nil }
        return (bundleID, reason)
    }

    private static func value(afterPrefix prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let v = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
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
            guard let content = readWholeText(url) else { continue }
            // JSON 形式を優先(既存の header/payload 分割 + summarize)。summarize が nil なら
            // 旧テキスト形式にフォールバック。JSON ファイルは分割が失敗しないため既存挙動は不変。
            let summary = splitHeaderAndPayload(content)
                .flatMap { summarize(headerLine: $0.header, payload: $0.payload) }
                ?? summarizeTextFormat(content)
            guard let summary, summary.bundleID == bundleID else { continue }
            return (url.path, summary.reason)
        }
        return nil
    }

    private static func readWholeText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func splitHeaderAndPayload(_ content: String) -> (header: String, payload: String)? {
        guard let newline = content.firstIndex(of: "\n") else { return nil }
        return (String(content[content.startIndex..<newline]), String(content[content.index(after: newline)...]))
    }
}
