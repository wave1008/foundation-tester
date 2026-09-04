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

    public static func stillStartingMessage(marker: String, serial: String) -> String {
        "the Android guest's system server on \(serial) is still starting"
            + " (adb reported: \(marker)) — settings and the bridge APK cannot be applied"
            + " until it settles; the next attempt retries"
    }
}
