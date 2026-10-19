// 自己修復(ロケータの指紋照合)の修正提案を、run の終わりにシナリオのソースへ書き戻す計画(純粋関数)。
// ユーザー決定: 受け手は git を導入している前提なので、ツールが直接書き戻してよい(利用者は差分を見てコミットする)。
// ファイルの読み書き・ロックは呼び手(`fleetest` の `HealSourceWriteBack`)。置換そのものは `HealFixApplier`。

import Foundation

public enum HealWriteBack {

    /// **発行側から送られてランナー機で走る run の印**(`RemoteDispatch.remoteRunCommand` が export する)。
    /// その run のプロジェクトはランナー機の写しなので書き戻さない —— 書き戻すのは結果を回収した発行側
    /// (写しを書き換えても利用者の手元には届かず、次の同期で消える)
    public static let dispatchedRunEnvironmentKey = "FT_DISPATCHED_RUN"

    /// **分割した run の子が、書く代わりに修正提案を追記するファイル**(親が `HealSourceWriteBack.Collection` で作って
    /// `DispatchTicketIssuer.childEnvironment` で渡す)。親は全部の子が終わってから全提案をまとめて1回だけ計画する ——
    /// 子ごとに書くと、子をまたいで食い違う提案(同じシナリオを別々の機械で回して別々の要素に一致した)を
    /// 先に書いた子が採ってしまい、「食い違う提案は書かない」が効かない
    public static let collectEnvironmentKey = "FT_HEAL_SUGGESTIONS_OUT"

    /// 書き戻しの排他(`<project>/.fleetest/` の固定ファイルの flock)。シナリオの子に書かせない
    /// (`ScenarioSandbox.writeDeniedPaths`。消されると別の inode を握った2者が同時に書く)
    public static let lockFileName = "heal-writeback.lock"

    public struct Suggestion: Codable, Equatable, Sendable {
        public let scenarioID: String
        /// 記録されたパス(子の cwd からの相対パス、cwd の外なら絶対パス。リモートで走った回はランナー機の cwd 基準)
        public let file: String
        public let line: Int
        public let oldSelector: String
        public let newSelector: String

        public init(scenarioID: String, file: String, line: Int, oldSelector: String, newSelector: String) {
            self.scenarioID = scenarioID
            self.file = file
            self.line = line
            self.oldSelector = oldSelector
            self.newSelector = newSelector
        }
    }

    public struct Skip: Equatable, Sendable {
        public let place: String
        public let reason: String
    }

    public struct Plan: Equatable, Sendable {
        /// 手元のファイルへ読み替えた fix(重複は1件に畳んである)
        public let fixes: [HealFixInput]
        public let skipped: [Skip]
    }

    /// 結果の記録から修正提案を集める。**旧・新セレクタと場所が揃った提案だけ**(指紋で治した回が出す強い提案)
    public static func suggestions(from records: [ScenarioRunRecord]) -> [Suggestion] {
        records.flatMap { record in
            (record.fixSuggestions ?? []).compactMap {
                suggestion(scenarioID: record.scenarioID, file: $0.file, line: $0.line,
                           oldSelector: $0.oldSelector, newSelector: $0.newSelector)
            }
        }
    }

    /// 実行のイベント(`fixSuggestion`)から1件。記録を作らずにシナリオを回す呼び手(MCP の `ft_run_scenario`)用
    public static func suggestion(from event: ScenarioEvent, fallbackScenarioID: String) -> Suggestion? {
        guard event.kind == "fixSuggestion" else { return nil }
        return suggestion(scenarioID: event.scenario ?? fallbackScenarioID, file: event.file, line: event.line,
                          oldSelector: event.oldSelector, newSelector: event.newSelector)
    }

    private static func suggestion(scenarioID: String, file: String?, line: Int?, oldSelector: String?,
                                   newSelector: String?) -> Suggestion? {
        guard let file, !file.isEmpty, let line, line > 0, let oldSelector, !oldSelector.isEmpty,
              let newSelector, !newSelector.isEmpty, oldSelector != newSelector else { return nil }
        return Suggestion(scenarioID: scenarioID, file: file, line: line,
                          oldSelector: oldSelector, newSelector: newSelector)
    }

    /// 書き戻す計画。`scenariosDir` = 手元のプロジェクトの `scenarios/`(実体パス)、`projectDirNames` = ランナー機の
    /// パスで探すプロジェクトのフォルダ名(ランナー機は `TestProjects/<プロジェクト名>/` へ写すので、手元のフォルダ名と
    /// プロジェクト名の両方)。**同じ場所(ファイル・行・旧セレクタ)に違う新セレクタが提案されたら書き戻さない**(どちらが正しいか
    /// ツールには言えない = 同じシナリオを複数のデバイスで回して、別々の要素に一致した形)
    public static func plan(_ suggestions: [Suggestion], scenariosDir: String, projectDirNames: [String],
                            currentDirectory: String, fileExists: (String) -> Bool) -> Plan {
        var skipped: [Skip] = []
        var grouped: [String: (fix: HealFixInput, news: Set<String>)] = [:]
        var order: [String] = []
        for s in suggestions {
            guard let local = localPath(for: s.file, scenariosDir: scenariosDir, projectDirNames: projectDirNames,
                                        currentDirectory: currentDirectory, fileExists: fileExists) else {
                skipped.append(Skip(place: "\(s.file):\(s.line)",
                                    reason: "the scenario file is not in this project's scenarios folder"))
                continue
            }
            let key = "\(local)\u{0}\(s.line)\u{0}\(s.oldSelector)"
            if var entry = grouped[key] {
                entry.news.insert(s.newSelector)
                grouped[key] = entry
            } else {
                grouped[key] = (HealFixInput(scenarioID: s.scenarioID, file: local, line: s.line,
                                             oldSelector: s.oldSelector, newSelector: s.newSelector,
                                             newComment: nil), [s.newSelector])
                order.append(key)
            }
        }
        var fixes: [HealFixInput] = []
        for key in order {
            guard let entry = grouped[key] else { continue }
            if entry.news.count > 1 {
                skipped.append(Skip(place: "\(entry.fix.file):\(entry.fix.line)",
                                    reason: "different selectors were suggested for \"\(entry.fix.oldSelector)\" ("
                                        + entry.news.sorted().map { "\"\($0)\"" }.joined(separator: ", ") + ")"))
                continue
            }
            fixes.append(entry.fix)
        }
        return Plan(fixes: fixes, skipped: skipped)
    }

    /// 記録されたパスを手元のファイルへ読み替える。**記録は子の cwd からの相対パス**(`FTRuntime.relativePath`。
    /// 子は親の cwd を継ぐ)か、cwd の外なら絶対パス。手元の `scenarios/` の下に解決できればそれ。そうでなければ
    /// `/<プロジェクトのフォルダ名>/scenarios/`(または先頭の `scenarios/`)より後ろを手元の `scenarios/` へ付け替える
    /// (ランナー機の記録 = ランナー機の cwd 基準)。`..` は解決してから判定し、読み替えた先が手元の `scenarios/` の外か
    /// 実在しなければ nil(**別のプロジェクトのファイルを書き換えない**)
    static func localPath(for recorded: String, scenariosDir: String, projectDirNames: [String],
                          currentDirectory: String, fileExists: (String) -> Bool) -> String? {
        guard !recorded.isEmpty else { return nil }
        let root = (scenariosDir.hasSuffix("/") ? String(scenariosDir.dropLast()) : scenariosDir) + "/"
        func inside(_ path: String) -> String? {
            let normalized = URL(fileURLWithPath: path).standardized.path
            return normalized.hasPrefix(root) && fileExists(normalized) ? normalized : nil
        }
        let absolute = recorded.hasPrefix("/") ? recorded
            : (currentDirectory.hasSuffix("/") ? currentDirectory : currentDirectory + "/") + recorded
        if let local = inside(absolute) { return local }
        let anchored = recorded.hasPrefix("/") ? recorded : "/" + recorded
        var tails: [String] = []
        for name in projectDirNames where !name.isEmpty {
            if let range = anchored.range(of: "/\(name)/scenarios/", options: .backwards) {
                tails.append(String(anchored[range.upperBound...]))
            }
        }
        if !recorded.hasPrefix("/"), recorded.hasPrefix("scenarios/") {
            tails.append(String(recorded.dropFirst("scenarios/".count)))
        }
        for tail in tails where !tail.isEmpty {
            if let local = inside(root + tail) { return local }
        }
        return nil
    }

    public struct SourceResult: Equatable, Sendable {
        public let source: String
        public let written: [HealFixInput]
        /// 行に既に新しいセレクタがあり、古いセレクタが無かった fix(並行する run や前の回が書き戻し済み)
        public let alreadyApplied: [HealFixInput]
        public let failures: [HealFixFailure]
    }

    /// 1ファイル分を書き換える。置換は `HealFixApplier`(古いセレクタがその行にちょうど1回)。
    /// **書き戻し済みの判定は置換に失敗した fix だけ**に当てる(古いのが残っていれば必ず置換を試みる)
    public static func apply(fixes: [HealFixInput], toSource source: String) -> SourceResult {
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)
        let lines = result.source.components(separatedBy: "\n")
        var already: [HealFixInput] = []
        var failures: [HealFixFailure] = []
        for failure in result.failures {
            guard let fix = fixes.first(where: { $0.id == failure.id }),
                  fix.line >= 1, fix.line <= lines.count else {
                failures.append(failure)
                continue
            }
            let line = lines[fix.line - 1]
            if !line.contains(ScenarioCodeGen.literal(fix.oldSelector)),
               line.contains(ScenarioCodeGen.literal(fix.newSelector)) {
                already.append(fix)
            } else {
                failures.append(failure)
            }
        }
        return SourceResult(source: result.source, written: result.applied, alreadyApplied: already,
                            failures: failures)
    }
}
