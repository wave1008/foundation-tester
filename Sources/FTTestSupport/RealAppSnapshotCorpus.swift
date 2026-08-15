// `Tests/Fixtures/RealAppSnapshots/` の実アプリ固定コーパスを読む共有ローダ(2026-08-15)。
//
// 以前は同じ decode ロジックが TreeCoverageTests / DuplicateRegionTests / FlowMatchModeTests /
// SweepHarnessTests の4箇所に逐語複製されていた。この読める集合(ファイル名の昇順)は
// 「発火する画面の集合を等号で固定する」各ゲートの母数そのものなので、パス解決や decode の
// オプションを変えるときは**全ゲートの基準値**に影響する。変えたら4テストすべてを見直すこと。

import FTCore
import Foundation

public enum RealAppSnapshotCorpus {

    /// `Sources/FTTestSupport/このファイル` から相対に `Tests/Fixtures/RealAppSnapshots` を指す。
    public static let directory: URL =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Sources/FTTestSupport
            .deletingLastPathComponent()      // Sources
            .deletingLastPathComponent()      // リポジトリ直下
            .appendingPathComponent("Tests/Fixtures/RealAppSnapshots")

    /// 全 `.json` をファイル名昇順で decode する。順序・集合は既存4テストの並びと一致させる契約。
    public static func all() throws -> [(name: String, snapshot: SnapshotResponse)] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { file in
                let url = directory.appendingPathComponent(file)
                return (String(file.dropLast(".json".count)),
                        try JSONDecoder().decode(SnapshotResponse.self,
                                                 from: try Data(contentsOf: url)))
            }
    }
}
