// `fleetest clean --simulator-poster-cache` の中核。停止中の全 iOS Simulator を挙げて
// PosterBoard のスナップショットキャッシュ(FTBridgeClient.SimulatorPosterCache)を消す。
// **RetentionSweeper.Category には入れない** —— このオプションを付けたときだけ動く
// (背景の自動掃除・素の `fleetest clean` には含まれない。ユーザー方針)。
// Booted の台は名前だけ出して飛ばす。消した量は台ごとに表示する。

import FTBridgeClient
import Foundation

enum SimulatorPosterCacheClean {
    static func run(dryRun: Bool, log: (String) -> Void) {
        guard let devices = try? SimulatorCatalog.devices() else {
            log("⚠️ simulator-poster-cache: could not list simulators (check xcrun simctl list devices)")
            return
        }
        var totalDirs = 0
        var totalFiles = 0
        var totalFreed: Int64 = 0
        for sim in devices {
            if sim.booted {
                log("· \(sim.name) (\(sim.udid)): skipped — booted")
                continue
            }
            let result = SimulatorPosterCache.purge(udid: sim.udid, dryRun: dryRun, logOnRemoval: false,
                                                    measureBytes: true)
            totalDirs += result.directoriesRemoved
            totalFiles += result.runtimeSnapshotFilesRemoved
            totalFreed += result.bytesFreed
            log("· \(sim.name) (\(sim.udid)): "
                + (dryRun ? "would free " : "freed ") + RetentionSweeper.bytesText(result.bytesFreed)
                + " (\(result.directoriesRemoved) cache dir(s), \(result.runtimeSnapshotFilesRemoved) runtime snapshot file(s))")
        }
        log((dryRun ? "🔍 would free " : "🧹 freed ") + RetentionSweeper.bytesText(totalFreed)
            + " of PosterBoard snapshots (\(totalDirs) cache dir(s), \(totalFiles) runtime snapshot file(s))")
    }
}
