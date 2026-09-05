// クラッシュしたアプリの process 証跡(MCP の switchedAppNote / DSL の失敗記録が共有する)。
// `adb shell pidof <pkg>` が空を返す = プロセスが死んでいる(2026-09-05・実機 Pixel 4a で
// #btn_crash_confirm から実測)。このとき ft_snapshot は前面へ移った launcher の木しか見せず
// 「別のアプリが前面」としか言えないため、クラッシュを利用者の操作と誤解される。
// adb が無い・失敗したときは nil で黙る(AndroidLogcat/AndroidForegroundWindows と同じ規律 —
// 判定材料が無いのに「落ちていない」と断定しない)。

import FTCore
import Foundation

public struct AndroidAppProcessEvidence: Equatable, Sendable {
    /// pidof が1件以上返した
    public let running: Bool
    /// crash バッファの最後の FATAL EXCEPTION ブロックのうち、この package の分だけ
    /// (先頭3行: "FATAL EXCEPTION: <thread>" / "Process: <pkg>, PID: n" / 例外の1行目)。
    /// 無ければ空(この package のクラッシュだと確認できなかった)
    public let crashSummary: [String]

    public init(running: Bool, crashSummary: [String]) {
        self.running = running
        self.crashSummary = crashSummary
    }
}

public enum AndroidAppProcessEvidenceQuery {

    /// 端末に問い合わせる(adb 2往復: pidof / logcat -d -b crash)
    public static func query(package: String, serial: String?) -> AndroidAppProcessEvidence? {
        guard let adb = try? AndroidDriver.findADB() else { return nil }
        var pidofArgs = [adb]
        if let serial { pidofArgs += ["-s", serial] }
        pidofArgs += ["shell", "pidof", package]
        guard let pidofResult = try? Shell.run(pidofArgs, timeout: 5) else { return nil }
        let running = pidofResult.status == 0
            && !pidofResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var logcatArgs = [adb]
        if let serial { logcatArgs += ["-s", serial] }
        // crash バッファは短いので -t で絞らず全件読んでからホスト側で package を選ぶ
        // (AndroidLogcat.recent と同じ理由: FATAL EXCEPTION の行は package 名を含まない)
        logcatArgs += ["logcat", "-d", "-b", "crash"]
        guard let logcatResult = try? Shell.run(logcatArgs, timeout: 10), logcatResult.status == 0
        else { return AndroidAppProcessEvidence(running: running, crashSummary: []) }

        return AndroidAppProcessEvidence(
            running: running,
            crashSummary: crashSummary(fromCrashLog: logcatResult.output, package: package))
    }

    /// `adb logcat -b crash` の生テキストから、**この package の最後の** `FATAL EXCEPTION`
    /// ブロックの先頭3行(タイムスタンプ・pid・タグ `E AndroidRuntime: ` の接頭辞を落とす)。
    /// 他の package のブロック(例: instrumentation ランナー自身のクラッシュ)は無視する
    public static func crashSummary(fromCrashLog log: String, package: String) -> [String] {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var blockStarts: [Int] = []
        for (index, line) in lines.enumerated() where strippedTag(line) == "FATAL EXCEPTION"
            || strippedTag(line).hasPrefix("FATAL EXCEPTION: ") {
            blockStarts.append(index)
        }
        // 後ろのブロックから探し、"Process: <package>," を持つ最初のもの(= 最後に起きたこの
        // package のクラッシュ)を使う
        for start in blockStarts.reversed() {
            let processLine = start + 1 < lines.count ? strippedTag(lines[start + 1]) : ""
            guard processLine.hasPrefix("Process: \(package),") else { continue }
            let reasonLine = start + 2 < lines.count ? strippedTag(lines[start + 2]) : nil
            return [strippedTag(lines[start]), processLine, reasonLine].compactMap { $0 }
        }
        return []
    }

    /// `08-09 10:00:00.300  5678  5679 E AndroidRuntime: FATAL EXCEPTION: main` →
    /// `FATAL EXCEPTION: main`(タイムスタンプ・pid・tid・タグを落とす)
    private static func strippedTag(_ line: String) -> String {
        guard let range = line.range(of: "AndroidRuntime: ") else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return String(line[range.upperBound...])
    }
}
