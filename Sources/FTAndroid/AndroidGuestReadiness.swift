// コールド起動直後(ブート/クイックブート復元直後)は sys.boot_completed=1 でも
// guest の system_server がまだ立ち上がっておらず、settings put / pm install が
// スタックトレース付きで失敗する。この2つの文字列だけがその状態の印。

import Foundation

public enum AndroidGuestReadiness {
    /// adb 出力に「guest の system_server がまだ立ち上がっていない」印があれば、
    /// マッチした行(trim 済み)を返す。無ければ nil
    public static func systemServerStartingMarker(in output: String) -> String? {
        let markers = ["before system providers are installed", "Can't find service:"]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if markers.contains(where: { trimmed.contains($0) }) {
                return trimmed
            }
        }
        return nil
    }

    /// adb shell が期限内に答えなかった(凍結・起動途中・極端な負荷)。`adb devices` には device のまま載る
    public static func noAnswerMessage(serial: String, seconds: Double) -> String {
        "\(serial) did not answer `adb shell` within \(Int(seconds))s (the device may be frozen or still"
            + " booting; `adb devices` can still list it) — the bridge was not started. If it stays this way,"
            + " restart the device"
    }

    public static func stillStartingMessage(marker: String, serial: String) -> String {
        "the Android guest's system server on \(serial) is still starting"
            + " (adb reported: \(marker)) — settings and the bridge APK cannot be applied"
            + " until it settles; the next attempt retries"
    }
}
