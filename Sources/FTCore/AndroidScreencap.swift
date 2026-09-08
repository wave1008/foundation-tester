import Foundation

/// Android 静止画取得の唯一の実装。**ブリッジを経由しない**(`adb exec-out screencap -p` の直叩き)。
/// 観測(モニターのポーリング等)がここを通しても副作用でブリッジを建てることが無いのが目的
/// —— `AndroidDriver.screenshot()` は `ensureBridge()` を通るため、無ければ建ててしまう。
/// WebView 合成(CDP)が要る撮影は引き続き `AndroidDriver.screenshot()` を使うこと。
public enum AndroidScreencap {
    /// `adb exec-out screencap -p` の PNG。失敗・空データなら nil。
    /// adb が刺さる(端末の抜き差し・スリープ)と EOF が来ないので、`timeout` で子孫ごと止める
    /// (呼び出し側が過渡的失敗として扱う)。
    public static func capturePNG(adb: String, serial: String, timeout: TimeInterval) -> Data? {
        guard let result = try? Shell.runData(
            [adb, "-s", serial, "exec-out", "screencap", "-p"], timeout: timeout),
              result.status == 0, !result.data.isEmpty else { return nil }
        return result.data
    }
}
