// 失敗時の証跡(要素一覧・スクリーンショット)を、Markdown レポートの隣に置く JSON。
// 書き手は FTDSL の ScenarioReportWriter(子プロセス)、読み手は fleetest-mcp の ft_run_scenario。
// fleetest-mcp は FTDSL をリンクしないので、両者が共有するのはこの型だけ。
// ファイル名は `<レポートの baseName>.failure.json` —— `scenario-<日時>-` の接頭辞を保つので、
// 保持容量の掃除(RetentionSweeper の日付抽出)がレポートと同じ日へ束ねて消す。

import Foundation

public struct FailureEvidence: Codable, Equatable, Sendable {
    public struct Scene: Codable, Equatable, Sendable {
        public var number: Int
        public var title: String
        /// 失敗時点の要素一覧(SnapshotRenderer の1要素1行)。取れなかったら nil
        public var elements: String?
        /// 失敗時のスクリーンショットのファイル名(このファイルと同じディレクトリ)。撮れなかったら nil
        public var screenshotFile: String?
        /// スクリーンショットが白フレームで証跡として無効(撮り直しても回復しなかった)
        public var screenshotBlank: Bool
        /// アプリより手前にあった別プロセスの window(手前が先)
        public var foregroundWindows: [String]
        /// アプリのプロセスが既に無かったことの表示行(Android のみ)
        public var appProcess: [String]

        public init(number: Int, title: String, elements: String?, screenshotFile: String?,
                    screenshotBlank: Bool, foregroundWindows: [String], appProcess: [String]) {
            self.number = number
            self.title = title
            self.elements = elements
            self.screenshotFile = screenshotFile
            self.screenshotBlank = screenshotBlank
            self.foregroundWindows = foregroundWindows
            self.appProcess = appProcess
        }
    }

    public var scenes: [Scene]

    public init(scenes: [Scene]) {
        self.scenes = scenes
    }

    /// レポート(`<baseName>.md`)に対応する証跡ファイルの場所
    public static func url(forReport report: URL) -> URL {
        report.deletingPathExtension().appendingPathExtension("failure.json")
    }

    /// 無い・読めない・壊れているときは nil(証跡は付け足しの情報で、無くても失敗の報告は成り立つ)
    public static func read(forReport report: URL) -> FailureEvidence? {
        guard let data = try? Data(contentsOf: url(forReport: report)) else { return nil }
        return try? JSONDecoder().decode(FailureEvidence.self, from: data)
    }

    public func write(forReport report: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.url(forReport: report), options: .atomic)
    }
}
