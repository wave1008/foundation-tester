// iOS 27 Simulator の PosterBoard(壁紙ギャラリー拡張)は、壁紙の版(`versions/<N>`)を作り直すたびに
// `<data>/Library/Application Support/PRBPosterExtensionDataStore/…/versions/<N>/scratch/
// SnapshotCache.cachedb`(壁紙プレビュー画像のキャッシュ)を作り、古い版の分を消さない
// (Apple の公式な認知は確認できていない。起動のたびではない —— 消さずに再起動しても束は増えず、版の数が増えた。
// 実測 15 台で合計約 187GB・1台最大 30GB。docs/design.md §12.4.2)。
// **simctl でブートする直前だけ**この関数を撃つ(古い版が増える機会そのものを減らす。
// 呼び出し口の一覧は Tests/FTCoreTests/SimulatorPosterCachePurgeWiringTests.swift が固定する)。
//
// **Booted の台には撃たない** —— PosterBoard が動いている最中に消すと書き込み中のファイルを
// 壊しうる。呼び出し側の保証をあてにせず、この関数自身が simctl の実状態を確かめる
// (一覧が読めないときも安全側で撃たない)。
//
// 消すのは `SnapshotCache.cachedb` という名前のディレクトリだけ(丸ごと・中には降りない)。
// それ以外(configurations・descriptors 本体・壁紙の設定)には一切触れない。
// 失敗(権限・途中で消えた等)は無視して次へ進む(起動を止めない)。

import FTCore
import Foundation

public enum SimulatorPosterCache {

    public struct PurgeResult: Sendable, Equatable {
        public let directoriesRemoved: Int
        public let bytesFreed: Int64
        /// true = Booted だったので何も見ていない(消せる/消せないの判定ではない)
        public let skippedBooted: Bool

        public init(directoriesRemoved: Int, bytesFreed: Int64, skippedBooted: Bool) {
            self.directoriesRemoved = directoriesRemoved
            self.bytesFreed = bytesFreed
            self.skippedBooted = skippedBooted
        }
    }

    /// `dryRun`: 消さずに数だけ数える(`fleetest clean --dry-run` 用)。
    /// `logOnRemoval`: 実際に消せた回だけ stderr へ1行(英語)出す。呼び手が自前で台ごとの
    /// 表示をする経路(`fleetest clean --simulator-poster-cache`)は false を渡して重複を避ける。
    /// `measureBytes`: 消す前に容量を数えるか。**起動の直前(既定)は数えない** —— 数えると全ファイルを
    /// もう一周なめるので、溜まった台の初回は削除そのもの(実測 48 秒)に同程度が上乗せされ、供給が遅れる。
    /// 容量を見せるのは人が打つ `fleetest clean` だけ
    @discardableResult
    public static func purge(udid: String, dryRun: Bool = false, logOnRemoval: Bool = true,
                             measureBytes: Bool = false) -> PurgeResult {
        purge(observation: SimulatorCatalog.shutdownObservation(udid: udid), udid: udid,
              dryRun: dryRun, logOnRemoval: logOnRemoval, measureBytes: measureBytes)
    }

    /// 状態注入用(テストが simctl を撃たずに `.stillBooted` / `.unreadable` の分岐を確かめる)
    static func purge(observation: SimulatorShutdownObservation, udid: String, dryRun: Bool = false,
                      logOnRemoval: Bool = true, measureBytes: Bool = false,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PurgeResult {
        guard shouldPurge(observation: observation) else {
            return PurgeResult(directoriesRemoved: 0, bytesFreed: 0, skippedBooted: true)
        }
        let store = posterStoreDirectory(udid: udid, home: home)
        let start = Date()
        let result = purgeCacheDirectories(under: store, dryRun: dryRun, measureBytes: measureBytes)
        if logOnRemoval, !dryRun, result.directoriesRemoved > 0 {
            let elapsed = Date().timeIntervalSince(start)
            let size = measureBytes ? " (\(bytesText(result.bytesFreed)))" : ""
            ConsoleOut.err("[fleetest] removed \(result.directoriesRemoved) PosterBoard snapshot"
                + " cache dir(s)\(size) for simulator \(udid)"
                + " in \(String(format: "%.1f", elapsed))s")
        }
        return result
    }

    /// **Shutdown のときだけ撃つ**。読めない(`.unreadable`)は安全側で撃たない
    static func shouldPurge(observation: SimulatorShutdownObservation) -> Bool {
        observation == .stopped
    }

    static func posterStoreDirectory(udid: String, home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Developer/CoreSimulator/Devices/\(udid)/data/Library/Application Support"
                + "/PRBPosterExtensionDataStore")
    }

    /// `store` が無ければ何もしない(そのシミュレータでまだ PosterBoard が一度も走っていない)
    /// `measureBytes` が false のとき bytesFreed は 0(数えていない = 0 バイトという意味ではない)
    static func purgeCacheDirectories(under store: URL, dryRun: Bool = false,
                                      measureBytes: Bool = true) -> PurgeResult {
        guard FileManager.default.fileExists(atPath: store.path) else {
            return PurgeResult(directoriesRemoved: 0, bytesFreed: 0, skippedBooted: false)
        }
        var removed = 0
        var freed: Int64 = 0
        for dir in findSnapshotCacheDirectories(under: store) {
            let bytes = measureBytes ? directorySize(dir) : 0
            if dryRun {
                removed += 1
                freed += bytes
                continue
            }
            guard (try? FileManager.default.removeItem(at: dir)) != nil else { continue }
            removed += 1
            freed += bytes
        }
        return PurgeResult(directoriesRemoved: removed, bytesFreed: freed, skippedBooted: false)
    }

    /// `root` の下を歩いて名前が `SnapshotCache.cachedb` のディレクトリを探す。
    /// **見つけたらその中には降りない**(入れ子の同名ディレクトリがあっても外側の1個を対象にする)
    static func findSnapshotCacheDirectories(under root: URL) -> [URL] {
        var result: [URL] = []
        var stack: [URL] = [root]
        while let dir = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                if entry.lastPathComponent == "SnapshotCache.cachedb" {
                    result.append(entry)
                } else {
                    stack.append(entry)
                }
            }
        }
        return result
    }

    static func directorySize(_ dir: URL) -> Int64 {
        var bytes: Int64 = 0
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
        }
        return bytes
    }

    static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
