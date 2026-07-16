// LastResultsStore.swift
// シナリオの直近実行結果を1ファイル/シナリオで記録する(`ftester run --failed` の絞り込み用)。
// ファイルはシナリオIDそのもの(拡張子なし・日本語可)で内容は "passed"/"failed"。
// 異なるシナリオは別ファイルなのでロック不要。同一シナリオの同時実行は元々非対応
// (1シナリオ1プロセスの原則。ScenarioHost.run 参照)。

import Foundation

public enum LastResultsStore {

    /// リポジトリ直下 .ftester/last-results/<projectName>/。
    /// 導出は MCPServer.swift root(of:) と同一(packageRoot 優先、無ければ rootURL から2階層遡る)。
    static func stateDir(project: TestProject) -> URL {
        let root = ScenarioHost.packageRoot() ?? project.rootURL
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".ftester/last-results")
            .appendingPathComponent(project.name)
    }

    /// 直近結果を記録する(best-effort)。失敗しても呼び出し側の実行結果には影響させない。
    public static func record(project: TestProject, scenarioID: String, passed: Bool) {
        record(stateDir: stateDir(project: project), scenarioID: scenarioID, passed: passed)
    }

    static func record(stateDir: URL, scenarioID: String, passed: Bool) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? (passed ? "passed" : "failed").write(
            to: stateDir.appendingPathComponent(scenarioID), atomically: true, encoding: .utf8)
    }

    /// 直近失敗したシナリオIDの集合。ディレクトリが無ければ空集合
    public static func failedIDs(project: TestProject) -> Set<String> {
        failedIDs(stateDir: stateDir(project: project))
    }

    static func failedIDs(stateDir: URL) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else {
            return []
        }
        var result: Set<String> = []
        for name in names {
            let content = try? String(
                contentsOf: stateDir.appendingPathComponent(name), encoding: .utf8)
            if content == "failed" { result.insert(name) }
        }
        return result
    }
}
