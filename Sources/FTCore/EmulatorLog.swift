// emulator stdout/stderr ログの所在(パス契約はここが唯一の正)。
// 書き込み: FTAndroid.DeviceBooter.startEmulator(ブート毎 truncate=emulator プロセス起動時のみ。
// guest reboot では truncate されない)/ 読み取り: FTAndroid.AndroidHealthProbe(Metal エラー計数)。
// **FTCore に居るのは RunOrchestrator が離脱理由にパスを添えるため**(qemu 自身の FATAL 終了は
// このログの末尾にしか出ない。FTCore は FTAndroid を参照できない)。

import Foundation

public enum EmulatorLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/fleetest/emulator")
    }

    public static func url(avdID: String) -> URL {
        directory.appendingPathComponent(avdID.replacingOccurrences(of: "/", with: "_") + ".log")
    }

    /// デバイスの論理名から実在するログファイルを引く。**AVD id は論理名と一致するとは限らない**
    /// (AndroidDeviceCatalog.canonicalAVDID は非英数字を "_" に畳んだ候補や displayName 一致でも
    /// 解決する)ので、素の名前 → 畳んだ名前の順に見て、**実在するものだけ**返す。
    /// `in:` はテスト用の差し替え口(既定パスはホスト共有なので直接見に行かない)
    public static func existingURL(deviceName: String, in dir: URL? = nil) -> URL? {
        let base = dir ?? directory
        let sanitized = String(deviceName.map { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        })
        var seen = Set<String>()
        for candidate in [deviceName, sanitized] where seen.insert(candidate).inserted {
            let url = base.appendingPathComponent(
                candidate.replacingOccurrences(of: "/", with: "_") + ".log")
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// ログ本文から FATAL/ERROR 行を拾う(emulator 自身の終了理由。`kill -9` 等の外的な終了は
    /// ログに何も残さないので、ここが空なら「理由は記録されていない」ということ)。純粋関数。
    /// **見るのは最後の起動の区間だけ** —— ログは起動ごとに `=== <時刻> emulator …` の見出しを付けて
    /// 追記される(DeviceBooter.startEmulator)ので、全体を見ると何日も前の起動の FATAL を今回の理由として引く。
    /// DeviceBooter.fatalLines もここへ委ねる(判定を2箇所に持たない)
    public static func fatalLines(in logText: String, limit: Int = 3) -> [String] {
        let session = lastSession(of: logText)
        var matches: [String] = []
        session.enumerateLines { line, _ in
            if line.contains("FATAL") || line.contains("ERROR") {
                matches.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return Array(matches.suffix(limit))
    }

    /// 最後の `=== ` 見出し行以降(見出しが無ければ全体)。純粋関数
    static func lastSession(of logText: String) -> Substring {
        if logText.hasPrefix("=== "), !logText.contains("\n=== ") { return logText[...] }
        guard let range = logText.range(of: "\n=== ", options: .backwards) else { return logText[...] }
        return logText[range.upperBound...]
    }

    /// 消失したエミュレータの離脱理由に添える導線。**ファイルを名指しできないときは
    /// ディレクトリを案内する** —— 無いパスを名指しすると導線として逆効果だが、置き場所を
    /// 言わないと DiagnosticReports 側を掘る遠回りになる(受け手報告 2026-08-24)。
    /// **ログに FATAL/ERROR 行が実在するときだけ「qemu FATAL」と断定する** —— `kill -9` 等
    /// 外部からの強制終了はログに何も書き残さないので、無いのに断定すると無関係な末尾行
    /// (Metal のエラー等)へ読み手を誘導する(実害)
    public static func dropoutHint(deviceName: String?, in dir: URL? = nil) -> String {
        let base = dir ?? directory
        guard let deviceName, let url = existingURL(deviceName: deviceName, in: base) else {
            return " — if the emulator process itself died, its exit reason is at the tail of its log"
                + " under \(base.path)"
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if let lastFatal = fatalLines(in: text).last {
            return " — the emulator's own exit reason is at the tail of \(url.path): \"\(lastFatal)\""
        }
        return " — its log at \(url.path) does not record an exit reason"
            + " (it may have been killed rather than exited on its own)"
    }
}
