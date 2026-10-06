// クラッシュしたアプリの process 証跡(MCP の switchedAppNote / DSL の失敗記録が共有する)。
// `adb shell pidof <pkg>` が空を返す = プロセスが死んでいる(実機 Pixel 4a で
// #btn_crash_confirm から実測)。このとき ft_snapshot は前面へ移った launcher の木しか見せず
// 「別のアプリが前面」としか言えないため、クラッシュを利用者の操作と誤解される。
// adb が無い・失敗したときは nil で黙る(AndroidLogcat/AndroidForegroundWindows と同じ規律 —
// 判定材料が無いのに「落ちていない」と断定しない)。**pidof 自体が「見つからない」で返す
// 非 0 終了と、adb 自体の断(device offline 等)は別物**(負荷テストで
// M1Ultra のエミュレータで実際に踏んだ: 一瞬の adb 断を「プロセスが居ない」と誤記録した。
// logcat ではアプリもブリッジも生きていた)。区別は `processAbsence` の1箇所だけに置く。

import FTCore
import Foundation

/// crash バッファに残るクラッシュの種類(AppCrashEvidence へ写す。文字列の後解析はしない)
public enum AndroidCrashKind: Equatable, Sendable {
    /// Java/Kotlin の未捕捉例外(`E AndroidRuntime: FATAL EXCEPTION`)
    case javaException
    /// ネイティブのシグナル(`F libc: Fatal signal` + `F DEBUG: pid: … >>> <pkg> <<<`)。
    /// Flutter(dart:ffi)・NDK・ゲームエンジンのクラッシュはこちらにしか残らない
    case nativeSignal
}

/// この package の最後のクラッシュ1件(crash バッファの中の位置 = 後に起きたほうを選ぶための順序)
public struct AndroidCrashBlock: Equatable, Sendable {
    public let kind: AndroidCrashKind
    public let lines: [String]
    let position: Int
}

public struct AndroidAppProcessEvidence: Equatable, Sendable {
    /// pidof が1件以上返した
    public let running: Bool
    /// crash バッファの最後のクラッシュのうち、この package の分だけ(`crashBlock` の lines)。
    /// 無ければ空(この package のクラッシュだと確認できなかった)
    public let crashSummary: [String]
    /// crashSummary の種類。crashSummary が空なら nil
    public let crashKind: AndroidCrashKind?

    public init(running: Bool, crashSummary: [String], crashKind: AndroidCrashKind? = nil) {
        self.running = running
        self.crashSummary = crashSummary
        self.crashKind = crashSummary.isEmpty ? nil : crashKind
    }
}

public enum AndroidAppProcessEvidenceQuery {

    /// 端末に問い合わせる(adb 2往復: pidof / logcat -d -b crash)
    public static func query(package: String, serial: String?) -> AndroidAppProcessEvidence? {
        guard AndroidPackageName.isShellSafe(package), let adb = try? AndroidDriver.findADB() else { return nil }
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

        let block = crashBlock(fromCrashLog: logcatResult.output, package: package)
        return AndroidAppProcessEvidence(running: running, crashSummary: block?.lines ?? [],
                                         crashKind: block?.kind)
    }

    /// 起点が分からないときの窓(秒)。ft_logs の既定と同じ5分(無制限には戻さない)
    public static let defaultAttributionWindowSeconds = 300

    /// クラッシュを帰属させる窓(秒)。**5秒の余裕を足す** —— 起点からクラッシュまでの実時間+adb 往復の
    /// ぶんを切り捨てて肝心のクラッシュ行を落とさないため。起点が分からなければ既定の5分
    public static func attributionWindowSeconds(since start: Date?, now: Date) -> Int {
        guard let start else { return defaultAttributionWindowSeconds }
        return max(5, Int(now.timeIntervalSince(start).rounded(.up)) + 5)
    }

    /// `query` の crashSummary を**起点以降**に絞り直す(MCP = 直近の launch / DSL = シナリオの開始)。
    /// `query` は crash バッファを時間で絞らず丸ごと読むので、素のままだと数分〜数時間前の**別プロセス**の
    /// クラッシュ(前の run・前のシナリオ)まで今の失敗に帰属させる。読み直せなければ空
    /// (言えないことは言わない)。プロセスが居る・クラッシュが無いときは adb を払わずそのまま返す
    public static func scoped(_ evidence: AndroidAppProcessEvidence, package: String, serial: String?,
                              since start: Date?, now: Date = Date()) -> AndroidAppProcessEvidence {
        guard !evidence.running, !evidence.crashSummary.isEmpty else { return evidence }
        let sinceSeconds = attributionWindowSeconds(since: start, now: now)
        guard let recent = try? AndroidLogcat.recent(serial: serial, packageName: nil, crashOnly: true,
                                                     sinceSeconds: sinceSeconds, maxLines: 5000)
        else { return AndroidAppProcessEvidence(running: evidence.running, crashSummary: []) }
        let block = crashBlock(fromCrashLog: recent.lines.joined(separator: "\n"), package: package)
        return AndroidAppProcessEvidence(running: evidence.running, crashSummary: block?.lines ?? [],
                                         crashKind: block?.kind)
    }

    /// `adb shell pidof <pkg>` の生出力から「アプリのプロセスが居ないか」を判定する純粋関数。
    /// - `true`: 居ない(pidof が空を返した = 本当に居ない)
    /// - `false`: 居る(pidof が pid を1件以上返した)
    /// - `nil`: **判定できない**(adb 自体が失敗した。device offline 等)。
    ///   ここが唯一の判定点 —— exit ≠ 0 を一律「プロセスが居ない」と読むと、adb 自体の断
    ///   (device offline / not found / unauthorized / daemon 起動失敗)を「クラッシュの疑い」と
    ///   誤記録する(負荷テストで M1Ultra のエミュレータで実際に踏んだ:
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

    /// `crashBlock` の lines(種類が要らない呼び手向け)
    public static func crashSummary(fromCrashLog log: String, package: String) -> [String] {
        crashBlock(fromCrashLog: log, package: package)?.lines ?? []
    }

    /// `adb logcat -b crash` の生テキストから、**この package の最後の**クラッシュ。
    /// Java の `FATAL EXCEPTION` ブロックとネイティブの `Fatal signal` ブロックのうち**後に起きたほう**。
    /// 他の package のブロック(例: instrumentation ランナー自身のクラッシュ)は無視する
    public static func crashBlock(fromCrashLog log: String, package: String) -> AndroidCrashBlock? {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let candidates = [javaBlock(lines: lines, package: package),
                          nativeBlock(lines: lines, package: package)].compactMap { $0 }
        return candidates.max { $0.position < $1.position }
    }

    /// **この package の最後の** `FATAL EXCEPTION` ブロックの先頭3行
    /// (タイムスタンプ・pid・タグ `E AndroidRuntime: ` の接頭辞を落とす)
    private static func javaBlock(lines: [String], package: String) -> AndroidCrashBlock? {
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
            return AndroidCrashBlock(kind: .javaException,
                                     lines: [strippedTag(lines[start]), processLine, reasonLine].compactMap { $0 },
                                     position: start)
        }
        return nil
    }

    /// **この package の最後の**ネイティブのクラッシュ。帰属は debuggerd の
    /// `pid: <n>, tid: …, name: …  >>> <package> <<<` の行で決める —— libc の `Fatal signal` 行の
    /// プロセス名は 15 文字で切れる(`ter.e2e.flutter`)ので package と照合できない。
    /// 要約 = [同じ pid の `Fatal signal …`(無ければ debuggerd の `signal …`), `Cause: …`(あれば), `pid: … >>> pkg <<<`]
    private static func nativeBlock(lines: [String], package: String) -> AndroidCrashBlock? {
        let messages = lines.map(logMessage)
        let marker = ">>> \(package) <<<"
        guard let pidIndex = messages.lastIndex(where: { $0.hasPrefix("pid: ") && $0.contains(marker) })
        else { return nil }
        let pidLine = messages[pidIndex]
        let pid = pidLine.dropFirst("pid: ".count).prefix { $0.isNumber }
        // 同じクラッシュの debuggerd の出力が終わる所(次の `*** ***` 区切りか、次の Fatal signal)まで
        let blockEnd = messages[(pidIndex + 1)...].firstIndex {
            $0.hasPrefix("*** *** ***") || $0.hasPrefix("Fatal signal ")
        } ?? messages.count
        let signalLine = messages[..<pidIndex].lastIndex {
            $0.hasPrefix("Fatal signal ") && $0.contains("pid \(pid) (")
        }.map { messages[$0] }
            ?? messages[(pidIndex + 1)..<blockEnd].first { $0.hasPrefix("signal ") }
        let causeLine = messages[(pidIndex + 1)..<blockEnd].first { $0.hasPrefix("Cause: ") }
        return AndroidCrashBlock(kind: .nativeSignal,
                                 lines: [signalLine, causeLine, pidLine].compactMap { $0 },
                                 position: pidIndex)
    }

    /// `10-02 22:30:59.552  3998  3998 F DEBUG   : pid: 3937, …` → `pid: 3937, …`
    /// (threadtime 書式の接頭辞 = 日付・時刻・pid・tid・レベル・タグを落とす。書式が違えば行をそのまま返す)
    static func logMessage(_ line: String) -> String {
        // 日付・時刻・pid・tid・レベル・「タグ : 本文」の6つ。タグと本文の区切りは6つ目の最初の ": "
        // (本文が ": " を含んでもタグは含まない)
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count == 6, parts[4].count == 1, "VDIWEF".contains(parts[4]),
              let separator = parts[5].range(of: ": ")
        else { return line.trimmingCharacters(in: .whitespaces) }
        return String(parts[5][separator.upperBound...])
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
