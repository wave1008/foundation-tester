// 実機の画面観測に差し込む「端末側の材料」と「無害な修復」。
//
// **run / api run の両経路が同じものを渡すためにここへ括り出す**。閉じ込めないと片方だけが
// 材料を渡す形になり、同じ端末について経路ごとに別の判定が出る(`fleetest run` と
// `fleetest api run` は別実装なので、この型の食い違いは緑のまま通る)。
//
// **Android 実機だけが材料を持つ**。iOS 実機は点灯状態を取る手段が無く(XCUIDevice にも
// devicectl にも無い)、消灯中はブリッジが応答せず絵も撮れないので nil = 不明のまま。
// 判定側はそれを「消灯かもしれない」側へ倒す(`FrozenVerdict.observe` の awake 引数)。

import FTAndroid
import FTCore

enum PhysicalScreenProbes {

    /// 端末の申告。**Android 実機だけ**が答える(それ以外は nil = 不明)
    static let awake: @Sendable (RunWorker) async -> Bool? = { worker in
        guard worker.platform == "android", worker.connection.physical,
              let serial = worker.connection.serial else { return nil }
        return AndroidPhysicalDevice.reportedAwake(serial: serial)
    }

    /// 画面の sleep/wake を1回。**再起動は撃たない**(持ち主の端末なので、取り返しのつく
    /// 操作しか自動では行わない)。結果は呼び手が観測し直して決める
    static let cycleScreen: @Sendable (RunWorker) async -> Void = { worker in
        guard worker.platform == "android", worker.connection.physical,
              let serial = worker.connection.serial else { return }
        await AndroidPhysicalDevice.cycleScreen(serial: serial)
    }
}
