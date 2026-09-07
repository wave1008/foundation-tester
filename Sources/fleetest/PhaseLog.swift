// FT_PHASE_LOG=1 のとき、run の各フェーズ所要時間を stderr に出す(固定費チューニング用の計測点。
// stdout に混ぜないのは NDJSON/整形出力を汚さないため)。

import Foundation
import FTCore

enum PhaseLog {
    static let enabled = ProcessInfo.processInfo.environment["FT_PHASE_LOG"] == "1"
    private static let start = Date()
    private static var last = start

    static func mark(_ name: String) {
        guard enabled else { return }
        let now = Date()
        let line = String(format: "[phase] %7.2fs (+%5.2fs) %@",
                          now.timeIntervalSince(start), now.timeIntervalSince(last), name)
        ConsoleOut.err(line)
        last = now
    }
}
