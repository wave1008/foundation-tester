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
        /// `-t` の絞り込みを端末の時間帯で組めなかった(ホストの時間帯で代用した)ときの注記。
        /// nil = 端末の時間帯で組めた、または絞り込み自体を使っていない
        public let cutoffNote: String?

        public init(lines: [String], scopedToPackage: Bool, cutoffNote: String? = nil) {
            self.lines = lines
            self.scopedToPackage = scopedToPackage
            self.cutoffNote = cutoffNote
        }
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
        var cutoffNote: String?
        if sinceSeconds > 0 {
            // `-t` は**端末のローカル時刻**で解釈される。ホストの時間帯で組むと、端末と時間帯が
            // 違うだけで(実機の海外設定・UTC のエミュレータ)数時間ぶん取りこぼす/余分に含む
            let offset = deviceUTCOffsetSeconds(adbPath: adbPath, serial: serial)
            if offset == nil {
                cutoffNote = "the device time zone could not be read (adb shell date +%z), so the"
                    + " \(sinceSeconds)s window was computed in the host time zone"
                    + " (\(TimeZone.current.identifier)) — it may be off by the zone difference"
            }
            args += ["-t", logcatTimeArgument(
                secondsAgo: sinceSeconds, now: Date(),
                deviceUTCOffsetSeconds: offset ?? TimeZone.current.secondsFromGMT())]
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
            scopedToPackage: packageName == nil || pid != nil || textFilterPackage != nil,
            cutoffNote: cutoffNote)
    }

    /// 端末の UTC オフセット(秒)を `adb shell date +%z` で1回だけ引く。失敗/読めない書式は nil
    /// (呼び出し側がホストの時間帯へ落とし、その旨を注記する)
    private static func deviceUTCOffsetSeconds(adbPath: String, serial: String?) -> Int? {
        var args = [adbPath]
        if let serial { args += ["-s", serial] }
        args += ["shell", "date", "+%z"]
        guard let result = try? Shell.run(args, timeout: 5), result.status == 0 else { return nil }
        return utcOffsetSeconds(fromDateZ: result.output)
    }

    /// `date +%z` の出力(`+0900` / `-0500`。末尾の改行・空白は無視)→ 秒。書式外は nil
    static func utcOffsetSeconds(fromDateZ output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 5, let sign = text.first, sign == "+" || sign == "-",
              text.dropFirst().allSatisfy(\.isNumber),
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)),
              hours <= 23, minutes <= 59 else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
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

    /// logcat `-t` の時刻絞り込み書式("MM-dd HH:mm:ss.SSS")。**端末のローカル時刻**で組む
    /// (deviceUTCOffsetSeconds = 端末の UTC オフセット秒。ホストの時間帯ではない)。
    /// 時計そのもののずれは残るが致命ではない(末尾 maxLines への切り詰めで上限は掛かる。
    /// エミュレータはホストと時刻同期・実機も NTP 同期が通常)
    static func logcatTimeArgument(secondsAgo: Int, now: Date, deviceUTCOffsetSeconds: Int) -> String {
        let cutoff = now.addingTimeInterval(-Double(secondsAgo))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: deviceUTCOffsetSeconds) ?? TimeZone(identifier: "UTC")!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: cutoff)
    }
}
