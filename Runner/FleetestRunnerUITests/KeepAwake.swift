// run 中に実機が自動ロックされるのを止める。Android の `svc power stayon true`
// (AndroidPhysicalDevice.prepareForRun)に相当するものが iOS には無い —— ホストから端末の
// 自動ロック設定を書き換える手段が無い(`devicectl device settings` は appearance/audio/
// biometrics/voiceover だけ・構成プロファイルにも「ロックしない」キーは無い)ので、
// **端末の中で動いている唯一の自分たちのコード**= このランナーが自分で起こし続ける。
//
// **`isIdleTimerDisabled` は効かない**(2026-08-27 実機実測 iPhone SE3 / iOS 26.5.2 / 自動ロック 30 秒):
// 10 秒ごとに貼り直しても、きっちり 30 秒で寝て `SBMainWorkspace ... reason: Locked` で
// launch が拒否された。ランナーは対象アプリを起動した時点で背面に回り、idle timer の申告は
// 前面アプリのものしか効かないため。申告自体は残してある(費用は代入1回で、ランナーが前面に
// 居る短い間だけは効く)が、**当てにしているのは下のパルス**。
//
// パルス = 「最後の HID 操作から一定時間経ったら、無害な入力を1発撃つ」。
// **ブリッジのアイドル時間で計ってはいけない** —— 待ちの最中もホストは木を読み続けるので
// ブリッジは忙しいまま、端末は入力が無いので寝る(この形がいちばん踏む)。数えるのは
// **入力**(BridgeRouter.mutatingPaths を通った要求)からの経過。
//
// 止め方: FT_KEEP_AWAKE=0(ホストの同名環境変数が BridgeLauncher 経由で渡る)。
// 玉の選択は FT_KEEP_AWAKE_PULSE=home|volume(既定 home)。

import UIKit
import XCTest

enum KeepAwake {

    /// 無入力がこれだけ続いたら1発撃つ(秒)。**iOS の自動ロックの最短が 30 秒**なので、
    /// それを跨がない値。上げると 30 秒設定の端末で寝る/下げると HUD を出す玉のとき目障りになる
    private static let pulseAfterIdleSeconds: TimeInterval = 25

    /// idle timer 申告の貼り直し間隔(秒)。前面/背面の遷移で落ちうるので1回では終わらせない
    private static let reassertIntervalSeconds: TimeInterval = 10

    /// 撃つ玉。home = 不可視(この機種では press(.home) が「ok を返すが何も起きない」)/
    /// volume = 確実な入力だが音量 HUD が出る。**どちらが起こせるかは実機でしか分からない**
    enum Pulse: String {
        case home
        case volume
    }

    private static let enabled = ProcessInfo.processInfo.environment["FT_KEEP_AWAKE"] != "0"
    private static let pulse = Pulse(
        rawValue: ProcessInfo.processInfo.environment["FT_KEEP_AWAKE_PULSE"] ?? "") ?? .home

    private static let lock = NSLock()
    private static var lastInput = Date()
    private static var lastAssert: Date?

    /// **メインスレッドから呼ぶこと**(UIApplication)。ブリッジのテストメソッドは main で回る
    static func start() {
        guard enabled else {
            NSLog("[fleetest] keep-awake off (FT_KEEP_AWAKE=0); the device may auto-lock mid-run")
            return
        }
        lock.lock(); lastInput = Date(); lock.unlock()
        assertIdleTimer()
        NSLog("[fleetest] keep-awake on (pulse=%@ after %.0fs without input)",
              pulse.rawValue, pulseAfterIdleSeconds)
    }

    /// HID を伴う要求(`BridgeRouter.inputPaths`)の始めと終わりに呼ぶ。
    /// **終わりでも戻す**のは、長い操作の実入力が終了時刻に近いため。
    /// 読み(スナップショット等)は入力ではないので戻さない(ポーリング中も端末は寝る)。
    ///
    /// **「処理中は撃たない」の数え上げは持たない**: ハンドラは
    /// `BridgeHTTPServer.dispatchToMain` が main へ流し、tick も main の RunLoop から呼ばれるので
    /// 両者は同時に走れない。数えると逆に、**NSException で巻き戻ったときに Swift の defer が
    /// 走らず**(dispatchToMain の `FTCatchObjCException` が握る)カウンタが 1 のまま張り付き、
    /// **以後パルスが永久に止まる** —— 直そうとしている死に方そのものになる
    static func noteUserInput() {
        lock.lock(); lastInput = Date(); lock.unlock()
    }

    /// 常駐ループの各周から呼ぶ。撃つ/貼り直す条件を満たさない周は何もしない
    static func tick() {
        guard enabled else { return }
        assertIdleTimerIfDue()
        lock.lock()
        let due = Date().timeIntervalSince(lastInput) >= pulseAfterIdleSeconds
        lock.unlock()
        guard due else { return }
        firePulse()
        lock.lock(); lastInput = Date(); lock.unlock()
    }

    private static func assertIdleTimerIfDue() {
        if let last = lastAssert, Date().timeIntervalSince(last) < reassertIntervalSeconds { return }
        assertIdleTimer()
    }

    private static func assertIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = true
        lastAssert = Date()
    }

    /// 撃つ。**シミュレータでは撃たない** —— 自動ロックが無いので用が無く、
    /// 音量ボタンは物理デバイス専用で例外になる
    private static func firePulse() {
        #if targetEnvironment(simulator)
        return
        #else
        switch pulse {
        case .home:
            XCUIDevice.shared.press(.home)
        case .volume:
            // 上げてすぐ下げる(端が来ていなければ音量は元に戻る)。HUD は出る
            XCUIDevice.shared.press(.volumeUp)
            XCUIDevice.shared.press(.volumeDown)
        }
        #endif
    }
}
