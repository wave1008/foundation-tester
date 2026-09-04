// ft_logs の本文レンダラ。**ブリッジ非依存が要点** — この機能が要る場面はまさにアプリが落ちて
// ブリッジごと消えた直後で、ドライバ経由(FTBridge instrumentation / in-app dylib)で掴もうとすると
// 先にエラーになって用を成さない。iOS はホスト側のファイル走査(SimulatorCrashReport)だけ、
// Android は serial の解決と adb(AndroidLogcat)だけで完結させる。
//
// iOS と Android は非対称(iOS はクラッシュレポートのみ・os_log の tail は出さない。ユーザー決定
// — simctl spawn log show は秒単位かかり出力も巨大なため)。この非対称を本文で明示する。

import FTAndroid
import FTBridgeClient
import Foundation

enum CrashLogs {

    /// mobile-mcp と同じ「生ログを全部返す」を避けるための最終防波堤。呼び出し側の maxLines が
    /// これを超えても、ここでクランプする
    static let hardMaxLines = 400

    /// ft_logs の本文。**throw しない** — 失敗も文章で返す(MCP ツールとして「診断できない」を
    /// 例外で終わらせると、まさに診断したい落ちた直後の状況で使い物にならない)。
    /// `physicalUDID`: 宛先が実機だと分かっているときだけ非 nil(**既定値は付けない** —
    /// 呼び出し忘れをコンパイルで止める)。**記録が無い(nil)ことは実機でない証拠にはならない**
    /// (best-effort。手掛かりが取れなければ従来どおりシミュレータの待ちへ落ちる)
    static func text(platform: String, bundleID: String?, serial: String?,
                     withinSeconds: Int, maxLines: Int, crashOnly: Bool,
                     physicalUDID: String?) async -> String {
        switch platform {
        case "ios":
            return await iosTextWaitingForReport(bundleID: bundleID, withinSeconds: withinSeconds,
                                                 physicalUDID: physicalUDID)
        case "android":
            return androidText(serial: serial, bundleID: bundleID, withinSeconds: withinSeconds,
                               maxLines: maxLines, crashOnly: crashOnly)
        default:
            return "Unknown platform \"\(platform)\" (expected \"ios\" or \"android\")."
        }
    }

    // MARK: - iOS

    /// **クラッシュ直後はまだ .ips が無い**(2026-08-09 実測: 落とした直後の呼び出しでは
    /// 見つからず、同じレポートが数秒後には在った)。ReportCrash の書き込みは非同期なので、
    /// 待たないと「落ちたのに落ちていない」と答える —— この道具でいちばん起きてはいけない誤り。
    /// **見つからないときだけ**短く待って引き直す(見つかれば即返るので通常の費用はゼロ)
    static let reportPollAttempts = 6
    static let reportPollIntervalNanos: UInt64 = 700_000_000

    /// iOS/Android 非対称の一文。`iosText` と `physicalDeviceText` の両方が使うので、
    /// ここ1箇所に置いて食い違いを起こさない
    static let asymmetryNote = "Unlike Android, iOS has no runtime log tail here (only crash"
        + " reports are readable this way) — if the app has not crashed, this tool has nothing"
        + " to show."

    static func iosTextWaitingForReport(bundleID: String?, withinSeconds: Int,
                                        physicalUDID: String?) async -> String {
        // **実機は待つだけ無駄**(件3): DiagnosticReports には端末のクラッシュが絶対に来ないので、
        // reportPollAttempts × reportPollIntervalNanos ≒ 4.2 秒はシミュレータのときにしか
        // 意味を持たない
        if let physicalUDID {
            return physicalDeviceText(bundleID: bundleID, udid: physicalUDID)
        }
        guard let bundleID, !bundleID.isEmpty else {
            return iosText(bundleID: bundleID, withinSeconds: withinSeconds)
        }
        var waited = 0.0
        for _ in 0..<reportPollAttempts {
            if SimulatorCrashReport.findRecent(bundleID: bundleID,
                                               within: TimeInterval(withinSeconds)) != nil { break }
            try? await Task.sleep(nanoseconds: reportPollIntervalNanos)
            waited += Double(reportPollIntervalNanos) / 1_000_000_000
        }
        return iosText(bundleID: bundleID, withinSeconds: withinSeconds, waitedSeconds: waited)
    }

    /// 宛先が実機だと分かっているときの本文。取り出し方まで言う(黙ると「ではどうやって
    /// 取るのか」で行き止まる) —— Xcode の Devices and Simulators ウィンドウ、または devicectl
    static func physicalDeviceText(bundleID: String?, udid: String) -> String {
        let scope = bundleID.map { " for \($0)" } ?? ""
        return "This destination is a physical device (\(udid))\(scope) — crash reports stay on"
            + " the device and never reach the Mac's DiagnosticReports, so this tool cannot read"
            + " them here. Pull them with Xcode's Window > Devices and Simulators (select the"
            + " device, \"View Device Logs\"), or `xcrun devicectl device copy from --device"
            + " \(udid) <container path> <destination>`. \(asymmetryNote)"
    }

    /// dir/now を差し替え可能にした internal 版(テストは実ホームディレクトリを汚さず
    /// 一時ディレクトリで検証する)
    static func iosText(bundleID: String?, withinSeconds: Int,
                        dir: URL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Logs/DiagnosticReports"),
                        now: Date = Date(),
                        waitedSeconds: Double = 0) -> String {
        guard let bundleID, !bundleID.isEmpty else {
            return "iOS crash lookup requires bundleID."
        }
        guard let found = SimulatorCrashReport.findRecent(bundleID: bundleID,
                                                           within: TimeInterval(withinSeconds),
                                                           dir: dir, now: now) else {
            // **実機のレポートはここには来ない**(端末に残り、Xcode で同期するまで Mac 側の
            // DiagnosticReports に現れない)。黙って「無い」と答えると実機で必ず誤答になる
            let waited = waitedSeconds > 0
                ? " Waited \(String(format: "%.1f", waitedSeconds))s in case one was still being written."
                : ""
            return "No crash report for \(bundleID) in the last \(withinSeconds)s.\(waited)"
                + " This reads the Mac's DiagnosticReports, which only receives simulator crashes —"
                + " a physical device keeps its reports on the device. \(asymmetryNote)"
        }
        let reason = found.reason ?? "unknown reason (the report did not parse)"
        // **必ず経過時間を出す**: 既定の窓は 300s あり、直前の run のクラッシュが残っていると
        // それを今回のものとして読む(2026-08-09 実測。11 分前のレポートを掴んだ)。
        // 新しいレポートは書き込みが数秒遅れるので、古い方を先に掴む競合も現実に起きる
        return "Crash found for \(bundleID)\(ageNote(path: found.path, now: now)): \(reason)"
            + "\nReport file: \(found.path)\n\(asymmetryNote)"
    }

    /// レポートファイルの更新時刻から「何秒前か」。読めなければ何も足さない
    private static func ageNote(path: String, now: Date) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return "" }
        let age = Int(now.timeIntervalSince(modified).rounded())
        guard age >= 0 else { return "" }
        return age < 60 ? " (\(age)s ago)" : " (\(age / 60)m \(age % 60)s ago — check this is not"
            + " a crash from an earlier run)"
    }

    // MARK: - Android

    /// AndroidLogcat.recent には十分大きな上限を渡して(実質切り詰めなしの)全件を取り、
    /// ここで正確な総数を数えてから hardMaxLines へクランプする。「N 行のうち末尾 M 行」を
    /// 言うには切り詰め前の総数が要るため
    private static let androidFetchUpperBound = 5000

    static func androidText(serial: String?, bundleID: String?, withinSeconds: Int,
                            maxLines: Int, crashOnly: Bool) -> String {
        let cap = min(maxLines > 0 ? maxLines : hardMaxLines, hardMaxLines)
        let output: AndroidLogcat.Output
        do {
            output = try AndroidLogcat.recent(serial: serial, packageName: bundleID, crashOnly: crashOnly,
                                              sinceSeconds: withinSeconds,
                                              maxLines: androidFetchUpperBound)
        } catch {
            return "Could not read Android logs: \(describe(error))"
        }
        let all = output.lines
        guard !all.isEmpty else {
            let scope = bundleID.map { " for \($0)" } ?? ""
            let buffer = crashOnly ? "crash buffer" : "main+crash buffers"
            return "No log lines\(scope) in the last \(withinSeconds)s (\(buffer))."
        }
        let shown = Array(all.suffix(cap))
        var header = shown.count < all.count
            ? "Showing the last \(shown.count) of \(all.count) line(s) (crashOnly=\(crashOnly))"
            : "\(shown.count) line(s) (crashOnly=\(crashOnly))"
        if let bundleID, !output.scopedToPackage {
            // 絞れなかったことを黙ると、他アプリのクラッシュを対象アプリのものと読む
            header += ". \(bundleID) is not running, so these lines could not be scoped to it"
                + " — other apps may appear below"
        }
        return header + ":\n" + shown.joined(separator: "\n")
    }

    /// DriverError は errorDescription を人が読める文にしている(LocalizedError)。
    /// ShellError(タイムアウト等)は CustomStringConvertible なので "\(error)" 側で拾える。
    /// どちらにも当たらない型のための最後の保険として "\(error)" を共通の末尾に置く
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
