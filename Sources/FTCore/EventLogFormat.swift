// EventLogFormat.swift
// results/runs/<YYYY-MM>/<runID>/events/*.ndjson の1行(`{"t":...,"stream":...,"event":{...}}` または
// `"event"` の代わりに `"text":"..."`)を、人間可読な行へ整形する純粋関数(fleetest results log)。
// 表示の書式は `FTCore.ScenarioLogFormatter`(ランナーの通常出力/MCP 応答が共用する既存の整形)に揃える
// —— 同じ ScenarioEvent を見た目だけ変えて二重に持たない。差分は時刻の先頭付与と、
// events ログにしか出ない行(生テキスト・壊れた行・未知の kind)への対応。
// **壊れた行・未知の kind も飛ばさず出す**(events/*.ndjson は既存の kind だけとは限らない
// = ScenarioEvent.swift のコメント「後発の追加フィールドは Optional」と同じ前方互換の姿勢)。

import Foundation

public enum EventLogFormat {
    /// events/*.ndjson の1行を、そのまま画面に出せる行(0行以上。failed step は detail を2行目に持つ)へ
    /// 整形する。JSON として壊れている行は "?? <原文>" として返す(黙って捨てない)
    public static func format(_ rawLine: String, timeZone: TimeZone = .current) -> [String] {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["?? \(trimmed)"]
        }
        let time = formattedTime(envelope["t"] as? String, timeZone: timeZone)

        if let text = envelope["text"] as? String {
            let streamTag = (envelope["stream"] as? String).map { "[\($0)] " } ?? ""
            return ["\(time) \(streamTag)\(text)"]
        }
        guard let eventDict = envelope["event"] as? [String: Any] else {
            return ["?? \(trimmed)"]
        }
        return eventLines(eventDict).map { "\(time) \($0)" }
    }

    // MARK: - timestamp

    /// ISO8601(ミリ秒つき/無し両方を試す)→ ローカル(既定)の `HH:mm:ss.SSS`。
    /// パース不能(欄が無い・壊れている)なら分かる範囲をそのまま返す
    private static func formattedTime(_ iso: String?, timeZone: TimeZone) -> String {
        guard let iso else { return "??:??:??.???" }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        guard let date = withFraction.date(from: iso) ?? withoutFraction.date(from: iso) else {
            return iso
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - event → 行

    private static func eventLines(_ eventDict: [String: Any]) -> [String] {
        guard let kind = eventDict["kind"] as? String else {
            return ["?? event without a kind"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: eventDict),
              let event = try? JSONDecoder().decode(ScenarioEvent.self, from: data) else {
            return ["?? \(kind) (undecodable event)"]
        }
        // 既知 kind の書式は ScenarioLogFormatter.lines(for:) と揃える(同じ絵を二重管理しない)。
        // duration は events ログだけの付加情報として付ける(通常出力には無い)
        switch kind {
        case "scenarioStarted":
            let title = (event.title?.isEmpty == false) ? " — \(event.title!)" : ""
            return ["▶ \(event.scenario ?? "")\(title)"]
        case "sceneStarted":
            let title = (event.sceneTitle?.isEmpty == false) ? ": \(event.sceneTitle!)" : ""
            return ["  scene \(event.scene ?? 0)\(title)"]
        case "step":
            return stepLines(event)
        case "sceneFinished":
            return []
        case "fixSuggestion":
            return ["    💡 Suggested fix: \(event.detail ?? "")"]
        case "paused":
            return ["    ⏸ Paused before \(event.index ?? 0). \(event.description ?? "")"]
        case "scenarioFinished":
            var lines = [event.passed == true ? "  → ✅ passed" : "  → ❌ failed"]
            if let report = event.reportPath { lines.append("  → report: \(report)") }
            return lines
        case "log":
            return [event.message ?? ""]
        case "deviceFrozen":
            let scenario = event.scenario.map { " (\($0))" } ?? ""
            return ["  🥶 device frozen\(scenario)"]
        default:
            return [naiveDump(kind: kind, eventDict: eventDict)]
        }
    }

    private static func stepLines(_ event: ScenarioEvent) -> [String] {
        let index = event.index ?? 0
        let section = event.section.map { "[\($0)] " } ?? ""
        let description = event.description ?? ""
        let duration = event.durationMs.map { " (\($0)ms)" } ?? ""
        switch event.status {
        case "passed":
            return ["    ✅ \(index). \(section)\(description)\(duration)"]
        case "passedViaFallback":
            return ["    ✅ \(index). \(section)\(description)(\(event.detail ?? ""))\(duration)"]
        case "healed":
            return ["    🔧 \(index). \(section)\(description) → \(event.detail ?? "")\(duration)"]
        case "failed":
            return ["    ❌ \(index). \(section)\(description)\(duration)",
                    "       \(event.detail ?? "")"]
        case "inconclusive":
            return ["    ❓ \(index). \(section)\(description) (inconclusive: \(event.detail ?? ""))\(duration)"]
        default:
            return ["    ⚠️ \(index). \(section)\(description) (skipped: \(event.detail ?? ""))\(duration)"]
        }
    }

    /// 未知 kind の受け皿。kind 名 + 残りの欄を `key=value` で素朴に並べる(推測で整形しない)
    private static func naiveDump(kind: String, eventDict: [String: Any]) -> String {
        let fields = eventDict
            .filter { $0.key != "kind" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(describe($0.value))" }
            .joined(separator: " ")
        return fields.isEmpty ? "  [\(kind)]" : "  [\(kind)] \(fields)"
    }

    private static func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        // JSONSerialization の数値 1/0 も `as? Bool` に通るので、真偽値は CFBoolean の型で見分ける
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return String(describing: value)
    }
}
