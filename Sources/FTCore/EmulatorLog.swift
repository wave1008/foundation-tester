// emulator stdout/stderr ログの所在(パス契約はここが唯一の正)。
// 書き込み: FTAndroid.DeviceBooter.startEmulator(ブート毎 truncate=emulator プロセス起動時のみ。
// guest reboot では truncate されない)/ 読み取り: FTAndroid.AndroidHealthProbe(Metal エラー計数)。
// **FTCore に居るのは RunOrchestrator が離脱理由にパスを添えるため**(qemu 自身の FATAL 終了は
// このログの末尾にしか出ない。FTCore は FTAndroid を参照できない)。

import Foundation

public enum EmulatorLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ftester/emulator")
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

    /// 消失したエミュレータの離脱理由に添える導線。**ファイルを名指しできないときは
    /// ディレクトリを案内する** —— 無いパスを名指しすると導線として逆効果だが、置き場所を
    /// 言わないと DiagnosticReports 側を掘る遠回りになる(受け手報告 2026-08-24)
    public static func dropoutHint(deviceName: String?, in dir: URL? = nil) -> String {
        let base = dir ?? directory
        if let deviceName, let url = existingURL(deviceName: deviceName, in: base) {
            return " — the emulator's own exit reason (a qemu FATAL) is at the tail of \(url.path)"
        }
        return " — if the emulator process itself died, its exit reason is at the tail of its log"
            + " under \(base.path)"
    }
}
