// RunRecordMemo.swift
// 長く動くプロセス(MCP サーバ)が、完了 run の解読結果をメモリに持つ(`RunResultsStore.scanRunsAndRecords` の `memo:`)。
// ディスクの `RunRecordPack` と同じ前提(完了 run の run.json / scenarios/*.json は追加専用 = stat が変わらなければ中身も同じ)で、
// 鍵は run の stat(`RunResultsStore.runStat`)だけ。**実行ファイルの鍵は要らない** —— 同じプロセスの同じ型が書いて読むので、
// 古い型で書いた控えを新しい型で読んで欄を黙って落とす形(パックが実行ファイルを鍵にする理由)が起きない。
// 中身はパックと同じ縮小記録(`RunRecordPack.trimmedForStorage`)= **集計にだけ使う**(trend は元ファイルを読み直す)。
// 持つのは最後の走査で見た run だけ(`retainOnly`)= 窓から落ちた run・消えた run は次の走査で手放す。

import Foundation
import Synchronization

public final class RunRecordMemo: Sendable {
    private struct Remembered {
        let runStatKey: String
        let contents: RunRecordPack.Contents
    }

    /// resultsDir のパス → run ディレクトリのパス → 解読結果(プロジェクトごとに分ける = 別プロジェクトの走査で手放さない)
    private let store = Mutex<[String: [String: Remembered]]>([:])

    public init() {}

    func lookup(resultsDir: URL, runDir: URL, runStatKey: String) -> RunRecordPack.Contents? {
        store.withLock { store in
            guard let remembered = store[resultsDir.path]?[runDir.path], remembered.runStatKey == runStatKey else { return nil }
            return remembered.contents
        }
    }

    func remember(_ contents: RunRecordPack.Contents, resultsDir: URL, runDir: URL) {
        store.withLock { store in
            store[resultsDir.path, default: [:]][runDir.path] = Remembered(runStatKey: contents.runStatKey, contents: contents)
        }
    }

    func retainOnly(resultsDir: URL, runDirs: Set<String>) {
        store.withLock { store in
            store[resultsDir.path] = store[resultsDir.path]?.filter { runDirs.contains($0.key) }
        }
    }

    /// テスト用: いま持っている run の数
    func count(resultsDir: URL) -> Int {
        store.withLock { $0[resultsDir.path]?.count ?? 0 }
    }
}
