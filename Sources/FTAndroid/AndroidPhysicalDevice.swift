// Android 実機だけに必要な run 前準備。エミュレータには無い前提を埋める:
//   - 実機は放置すると画面が消灯しロック画面に入る。ロック中は
//     UiAutomation.getRootInActiveWindow() が対象アプリにならず launch が 500
//     (「アプリの画面が表示されませんでした」)、スクショも真っ黒になる(2026-07-25 の実害)
//   - PIN/パターンが設定された端末は adb から解除できない。docs 側で「画面ロックなし」を要件に
//     している(解除できないと全シナリオが launch 500 で落ちる)
// 副作用(stay-awake)は端末に永続するため、呼び出し側が 1 回だけ知らせること。
//
// **ロック判定に使ってよい信号は topResumedActivity の有無だけ**(Pixel 4a/Android 13 実測 2026-07-25)。
// `isKeyguardShowing` と `mCurrentFocus` は、実際には解除されランチャーが見えている状態でも
// 古い値(true / NotificationShade)を返し続けた。この2つを信じると解除済みを失敗と誤報する。

import FTCore
import Foundation

public enum AndroidPhysicalDevice {

    /// wm dismiss-keyguard は非同期で、解除完了まで実測 3〜7 秒かかる(同上)。
    /// 待たずに launch すると初回シナリオだけが 500 で落ちる(8 run 中 1 件の flake だった)
    private static let unlockTimeoutSeconds = 20.0

    /// 画面を起こし、ロック画面を解除し、run 中に再消灯しないようにする。
    /// 解除できなくても throw しない(混在プロファイルの iOS 側を殺さない。launch の 500 で顕在化する)
    public static func prepareForRun(serial: String,
                                     log: (String) -> Void = { _ in }) async {
        guard let adb = try? AndroidDriver.findADB() else { return }
        func shell(_ args: [String], _ timeout: Double = 10) {
            _ = try? Shell.run([adb, "-s", serial] + args, timeout: timeout)
        }

        // **消灯抑止はツールの仕事にしない**(2026-09-05 ユーザー決定)。端末の画面設定は
        // 端末側で決めるもので、`stayon` は true も false も撃たない —— false を「旧版の後始末」として
        // 撃っていた頃は、持ち主が開発者オプションで立てた「充電中はスリープしない」(7)と区別できず
        // run・MCP のたびに 0 へ消していた(2026-09-11 Pixel 3a で 7 → 0)。
        // 点灯と解除は残す(ロック中は launch が 500 で落ちるため run の前提であって抑止ではない)。
        // 途中で消えた分は `wakeIfAsleep` がシナリオごと・MCP の呼び出しごとに起こし直す
        shell(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        // 点灯を待ってから解除する。Dozing(AOD)中に投げた dismiss-keyguard は黙って無視される
        for _ in 0..<10 where !isAwake(adb: adb, serial: serial) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        shell(["shell", "wm", "dismiss-keyguard"])

        let deadline = Date().addingTimeInterval(unlockTimeoutSeconds)
        while Date() < deadline {
            if hasResumedActivity(adb: adb, serial: serial) {
                log("✔ \(serial): screen woken and unlocked"
                    + " (the device keeps its own screen-timeout setting)")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("⚠️ \(serial): could not unlock the lock screen"
            + " (a PIN/pattern lock cannot be cleared over adb — set the device to no lock)")
    }

    /// **消灯・ロック中のときだけ** `prepareForRun` を撃つ(点いていて解除済みなら何もしない)。起こしたら true。
    /// 起こすのが run 開始時の1回だけだと、途中で1回消えた後の全シナリオが「アプリが前面に来ない」
    /// (launch の 500)で落ち、消灯に一言も触れなかった(2026-09-11 Pixel 4a: 1回の消灯で 22/24 赤)。
    /// 確認は1往復(端末側で grep。Pixel 4a / 3a で 0.07〜0.15 秒)なので、シナリオごと・MCP の呼び出しごとに払う
    @discardableResult
    public static func wakeIfAsleep(serial: String, log: (String) -> Void = { _ in }) async -> Bool {
        guard screenAwakeAndUnlocked(serial: serial) == false else { return false }
        log("⚠️ \(serial): the screen was off or locked — waking and unlocking it before continuing"
            + " (the tool does not keep the screen on; the device's own settings decide when it turns off)")
        // **成功の「✔」行は流さない**: シナリオの子では stderr の1行が結果の errorLogs(上限5件)の1枠を
        // 取り、情報行が本物の失敗の手掛かりを押し出す(ScenarioRunnerMain の FMHealth の注意と同じ)。
        // 解除できなかった「⚠️」は残す
        await prepareForRun(serial: serial, log: { line in
            if !line.hasPrefix("✔") { log(line) }
        })
        return true
    }

    /// 画面が点いていてロックも外れているか(1往復・端末側で grep)。取れなければ nil
    public static func screenAwakeAndUnlocked(serial: String) -> Bool? {
        guard let adb = try? AndroidDriver.findADB(),
              let output = try? Shell.run(
                [adb, "-s", serial, "shell",
                 "dumpsys power | grep -m1 mWakefulness=; "
                    + "dumpsys activity activities | grep -m1 topResumedActivity="],
                timeout: 15).output else { return nil }
        return awakeAndUnlocked(checkOutput: output)
    }

    /// `wakeIfAsleep` の確認の出力を読む純粋関数。**取れなかった(空)は nil** = 起こさない
    /// (確かめられないのに撃たない)。ロックの判定は topResumedActivity の有無だけ(ファイル冒頭)
    static func awakeAndUnlocked(checkOutput output: String) -> Bool? {
        guard output.contains("mWakefulness=") else { return nil }
        return output.contains("mWakefulness=Awake") && output.contains("topResumedActivity=")
    }

    /// dumpsys power の mWakefulness(Awake / Dozing / Asleep)。取得できなければ Awake 扱い
    private static func isAwake(adb: String, serial: String) -> Bool {
        guard let output = try? Shell.run(
            [adb, "-s", serial, "shell", "dumpsys", "power"], timeout: 15).output else { return true }
        return output.contains("mWakefulness=Awake")
    }

    /// 前面に resume 済みアクティビティがあるか。ロック中はどのアクティビティも resume されないため
    /// この行自体が消える = 唯一信用できるロック判定(ファイル冒頭の注意参照)
    private static func hasResumedActivity(adb: String, serial: String) -> Bool {
        guard let output = try? Shell.run(
            [adb, "-s", serial, "shell", "dumpsys", "activity", "activities"],
            timeout: 15).output else { return false }
        return output.contains("topResumedActivity=")
    }
}
