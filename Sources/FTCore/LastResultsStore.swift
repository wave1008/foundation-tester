// LastResultsStore.swift
// シナリオの直近実行結果を1ファイル/シナリオで記録する(`fleetest run --failed` の絞り込み用)。
// ファイルはシナリオIDそのもの(拡張子なし・日本語可)で内容は "passed"/"failed"。
// 異なるシナリオは別ファイルなのでロック不要。同一シナリオの同時実行は元々非対応
// (1シナリオ1プロセスの原則。ScenarioHost.run 参照)。
//
// **記録は (project, profile) 単位**。1プロジェクトの記録を1つに畳むと、
// 別プロファイル/別プラットフォームの緑が別プロファイルの赤を上書きし、`--failed` が
// 拾えなくなる(vscode-fleetest 側は lastResults.ts が「どれか1プロファイルでも failed なら
// failed」として複数プロファイル分を1つのアイコンへ畳む。両方読む・書く側の規則を合わせること)。

import Foundation

public enum LastResultsStore {

    /// profile-less な run(`--profile` 無し)の専用区分。プロファイル名はファイル名の一部として
    /// 使われるため、実在のプロファイル名と衝突しないよう予約語にする("_" 始まりはプロファイル名
    /// のバリデーションでは特に禁止されていないが、実運用で使われることはまず無い)
    public static let noProfileKey = "_no-profile"

    /// 受け手パッケージ直下 .fleetest/last-results/<projectName>/<profile>/(packageRoot 優先、
    /// 無ければ rootURL から2階層遡る)。TestProjects/ を持つ側が正で、ツール本体の
    /// RepoRoot.find()(ブリッジ資産の在り処)とは別物。**`profile` は必須引数**
    /// (nil は「profile-less」の意味で `noProfileKey` へ畳む。既定値を置くと呼び出し忘れが
    /// コンパイルで見えなくなる)
    static func stateDir(project: TestProject, profile: String?) -> URL {
        let root = ScenarioHost.packageRoot() ?? project.rootURL
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".fleetest/last-results")
            .appendingPathComponent(project.name)
            .appendingPathComponent(profile ?? noProfileKey)
    }

    /// 直近結果を記録する(best-effort)。失敗しても呼び出し側の実行結果には影響させない。
    public static func record(project: TestProject, scenarioID: String, passed: Bool, profile: String?) {
        record(stateDir: stateDir(project: project, profile: profile), scenarioID: scenarioID, passed: passed)
    }

    static func record(stateDir: URL, scenarioID: String, passed: Bool) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? (passed ? "passed" : "failed").write(
            to: stateDir.appendingPathComponent(scenarioID), atomically: true, encoding: .utf8)
    }

    /// 直近失敗したシナリオIDの集合(この `(project, profile)` の記録だけ)。ディレクトリが
    /// 無ければ空集合
    public static func failedIDs(project: TestProject, profile: String?) -> Set<String> {
        failedIDs(stateDir: stateDir(project: project, profile: profile))
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
