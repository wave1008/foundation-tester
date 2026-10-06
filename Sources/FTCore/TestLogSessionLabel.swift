// TestLogSessionLabel.swift
// `TestLog.directoryForLog`(FTDSL)の run のフォルダ名 `yyyy-MM-dd_HHmmss`(Shirates の `TestLog.sessionStartTimeLabel` と
// 同じ形・ローカル時刻)。書き手は3者で、形はここの1箇所: 親(`ScenarioHost.run` が `--run-started-at` で子へ渡す)・
// 子(フォルダを作る)・保持容量の掃除(`RetentionSweeper.reportSessions` が日付を読む)
import Foundation

public enum TestLogSessionLabel {
    /// このプロセスの最初の参照の時刻(Shirates のセッション = JVM 1つと同じく、親プロセス1つで1つ。
    /// run / api run は1 run = 1プロセス、MCP は長生きするので複数の run が同じフォルダに入る)
    public static let processStart: String = label(Date())

    public static func label(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// フォルダ名がこの形なら日付(`yyyyMMdd` = レポートのファイル名と同じ日の単位)。違えば nil = 利用者のフォルダ
    public static func day(ofLabel name: String) -> String? {
        guard name.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        return name.prefix(10).replacingOccurrences(of: "-", with: "")
    }
}

/// `TestLog.directoryForLog` / `TestLog.directoryForTemp`(FTDSL)のパス(I/O なし)。組み立てる子(ScenarioRunnerMain)は
/// FTDSL の内部を呼べないので、ここに置く
public enum TestLogPaths {
    /// `<reportDir>/<runStartedAt>/<クラス名>/`
    public static func logDirectory(reportDir: URL, runStartedAt: String, className: String) -> URL {
        reportDir.appendingPathComponent(runStartedAt, isDirectory: true)
            .appendingPathComponent(pathComponent(className), isDirectory: true)
    }

    /// `<base>/<シナリオ ID>-<UUID>/`(同じシナリオが並列に走っても衝突しない)
    public static func temporaryDirectory(base: URL, scenarioID: String) -> URL {
        base.appendingPathComponent(pathComponent(scenarioID) + "-" + UUID().uuidString, isDirectory: true)
    }

    /// クラス名・シナリオ ID をフォルダ名1つにする(`/` と `:` は区切りになるので `_` に)
    static func pathComponent(_ name: String) -> String {
        let replaced = String(name.map { $0 == "/" || $0 == ":" ? "_" : $0 })
        return replaced.isEmpty || replaced == "." || replaced == ".." ? "_" : replaced
    }
}
