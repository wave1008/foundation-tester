// クラッシュしたアプリの process 証跡(MCP の switchedAppNote / DSL の失敗記録が共有する)。
// `adb shell pidof <pkg>` が空を返す = プロセスが死んでいる(2026-09-05・実機 Pixel 4a で
// #btn_crash_confirm から実測)。このとき ft_snapshot は前面へ移った launcher の木しか見せず
// 「別のアプリが前面」としか言えないため、クラッシュを利用者の操作と誤解される。
// adb が無い・失敗したときは nil で黙る(AndroidLogcat/AndroidForegroundWindows と同じ規律 —
// 判定材料が無いのに「落ちていない」と断定しない)。**pidof 自体が「見つからない」で返す
// 非 0 終了と、adb 自体の断(device offline 等)は別物**(2026-09-16 の負荷テストで
// M1Ultra のエミュレータで実際に踏んだ: 一瞬の adb 断を「プロセスが居ない」と誤記録した。
// logcat ではアプリもブリッジも生きていた)。区別は `processAbsence` の1箇所だけに置く。

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
        // adb 自体が失敗した回(device offline 等)は「判定できない」= 何も言わない。
        // exit ≠ 0 を一律「プロセスが居ない」と読まない(processAbsence 参照)
        guard let absent = processAbsence(status: pidofResult.status, output: pidofResult.output)
        else { return nil }
        let running = !absent

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

    /// `adb shell pidof <pkg>` の生出力から「アプリのプロセスが居ないか」を判定する純粋関数。
    /// - `true`: 居ない(pidof が空を返した = 本当に居ない)
    /// - `false`: 居る(pidof が pid を1件以上返した)
    /// - `nil`: **判定できない**(adb 自体が失敗した。device offline 等)。
    ///   ここが唯一の判定点 —— exit ≠ 0 を一律「プロセスが居ない」と読むと、adb 自体の断
    ///   (device offline / not found / unauthorized / daemon 起動失敗)を「クラッシュの疑い」と
    ///   誤記録する(2026-09-16 の負荷テストで M1Ultra のエミュレータで実際に踏んだ:
    ///   一瞬の `adb: device offline` が「プロセスが居ない」と記録された。logcat ではアプリも
    ///   ブリッジも生きていた)。**言えないときは欄ごと省く**(失敗の記録の規律。呼び出し元は
    ///   `query` 経由で nil を受け取り、`core.appProcessEvidence` は空配列を返す)
    /// `status` は呼び出し元(`Shell.Result`)とシグネチャを揃えるために受け取るが、判定には
    /// 使わない —— `adb shell pidof` の exit code は「pidof が見つけられなかった」(通常の
    /// 非 0 終了)と「adb 自体が失敗した」を区別しない。区別できるのは出力の中身だけ
    /// (adb は自分のエラーを `output` へ書く。`looksLikeADBFailure` 参照)
    static func processAbsence(status: Int32, output: String) -> Bool? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeADBFailure(trimmed) { return nil }
        // **非 0 終了で何か書いている = adb 側の失敗**(pidof は「居ない」を非 0 + 空で返す)。
        // 文言の一覧に無いエラー(`error: protocol fault` 等)をここで拾う ——
        // 一覧だけに頼ると、知らない文言の失敗を「居る」と読んでしまう
        if status != 0, !trimmed.isEmpty { return nil }
        return trimmed.isEmpty
    }

    /// adb 自体の失敗を示す既知の接頭辞・部分文字列。**規則はここ1箇所だけに置く**
    /// (実測した文言だけを列挙する。書式が変わっても気付けないので推測で広げない)。
    /// `Shell.run` は stdout/stderr を1本の `output` へ混合する(既定 mergeStderr: true)ため、
    /// adb がエラーを stderr へ書いても `output` に乗る
    private static func looksLikeADBFailure(_ trimmed: String) -> Bool {
        let markers = [
            "adb: ", "error: device", "error: no devices", "device offline",
            "device unauthorized", "device not found", "daemon not running",
            "daemon still not running", "no devices/emulators found",
        ]
        let lower = trimmed.lowercased()
        return markers.contains { lower.contains($0.lowercased()) }
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
