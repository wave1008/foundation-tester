// adb logcat の取得(ft_logs の Android 側材料)。AndroidDriver.adb(_:) と同じ ADB パス解決
// (AndroidDriver.findADB())を使う — 別解決を持つとどちらかだけが adb を見失う事故になる。
// 常に -d(ダンプして即終了)を付け、ストリームで固まらないようにする。

import FTCore
import Foundation

public enum AndroidLogcat {

    public struct Output: Equatable {
        public let lines: [String]
        /// packageName を渡したのに絞り込めなかった(プロセスが既に居ない)= 他アプリの行が混ざる
        public let scopedToPackage: Bool
    }

    /// 直近のログ行。crashOnly なら crash バッファのみ、そうでなければ main+crash。
    /// packageName を渡すと pidof で対象プロセスの pid を引き `--pid` で絞る。
    /// **pidof が空を返すのはアプリが落ちて居なくなった正常ケース**(この道具の本命)。
    /// そのときテキスト一致へ落とすのは crash バッファでは有害 —— `FATAL EXCEPTION` と
    /// スタックトレースの行はパッケージ名を含まず、名指しで残るのは `Process:` の1行だけなので、
    /// **原因そのものを捨てる**。crash バッファは短いので絞らずに返し、混在は呼び出し側が明示する
    public static func recent(serial: String?, packageName: String?, crashOnly: Bool,
                              sinceSeconds: Int, maxLines: Int) throws -> Output {
        let adbPath = try AndroidDriver.findADB()

        let pid = packageName.flatMap { resolvePID(adbPath: adbPath, serial: serial, packageName: $0) }

        var args = [adbPath]
        if let serial { args += ["-s", serial] }
        args += ["logcat", "-d"]
        args += crashOnly ? ["-b", "crash"] : ["-b", "main", "-b", "crash"]
        if sinceSeconds > 0 {
            args += ["-t", logcatTimeArgument(secondsAgo: sinceSeconds, now: Date())]
        }
        if let pid {
            args += ["--pid", pid]
        }

        // 数秒でも固まると ft_logs の「ブリッジ抜きで診断する」目的そのものが崩れるため timeout を必ず付ける
        let result = try Shell.run(args, timeout: 10)
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "adb logcat failed (is exactly one device connected, or was -s given?): \(result.tail)")
        }
        // pid が引けていれば --pid が既に絞っている。引けなかったときのテキスト一致は
        // main バッファでだけ使う(crash バッファでやるとスタックトレースを捨てる。上のコメント参照)
        let textFilterPackage = (pid == nil && !crashOnly) ? packageName : nil
        return Output(
            lines: filter(rawOutput: result.output, packageName: textFilterPackage, maxLines: maxLines),
            scopedToPackage: packageName == nil || pid != nil || textFilterPackage != nil)
    }

    /// 生の logcat テキストを行へ分解し、package で絞り(部分一致)、末尾 maxLines へ切り詰める。
    /// maxLines <= 0 は「切り詰めない」。
    static func filter(rawOutput: String, packageName: String?, maxLines: Int) -> [String] {
        var lines = rawOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let packageName, !packageName.isEmpty {
            lines = lines.filter { $0.contains(packageName) }
        }
        guard maxLines > 0, lines.count > maxLines else { return lines }
        return Array(lines.suffix(maxLines))
    }

    /// `adb shell pidof <pkg>` で pid を引く。複数返る(同名プロセス)場合は先頭のみ使う。
    /// 空/失敗はどちらも nil(呼び出し側がテキスト一致へフォールバックする)
    private static func resolvePID(adbPath: String, serial: String?, packageName: String) -> String? {
        var args = [adbPath]
        if let serial { args += ["-s", serial] }
        args += ["shell", "pidof", packageName]
        guard let result = try? Shell.run(args, timeout: 5), result.status == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: " ").first.map(String.init)
    }

    /// logcat `-t` の時刻絞り込み書式("MM-dd HH:mm:ss.SSS"、端末のローカル時刻)。
    /// 端末とホストの時計がずれていれば取りこぼす/余分に含みうるが、致命ではない
    /// (最終的に末尾 maxLines への切り詰めで上限は掛かる。エミュレータはホストと時刻同期される
    /// のが通常で、実機も NTP 同期が通常のため実害は小さい想定)
    static func logcatTimeArgument(secondsAgo: Int, now: Date) -> String {
        let cutoff = now.addingTimeInterval(-Double(secondsAgo))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: cutoff)
    }
}
