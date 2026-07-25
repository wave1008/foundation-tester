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

        // 充電中は消灯させない。引数 "usb" だと USB 給電時のみ(bitmask 2)で、AC として
        // 認識されるケーブル/ハブでは効かない(実測)。true = AC|USB|WIRELESS(7)を使う
        shell(["shell", "svc", "power", "stayon", "true"])
        shell(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        // 点灯を待ってから解除する。Dozing(AOD)中に投げた dismiss-keyguard は黙って無視される
        for _ in 0..<10 where !isAwake(adb: adb, serial: serial) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        shell(["shell", "wm", "dismiss-keyguard"])

        let deadline = Date().addingTimeInterval(unlockTimeoutSeconds)
        while Date() < deadline {
            if hasResumedActivity(adb: adb, serial: serial) {
                log("✔ \(serial): 画面点灯・ロック解除・消灯抑止を適用しました")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("⚠️ \(serial): ロック画面を解除できませんでした"
            + "(画面ロックが PIN/パターンだと adb からは解除できません。ロックなしに設定してください)")
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
