// ApiApplyHealCommand.swift
// VSCode拡張向け: 自己修復の修復候補を stdin から受け取り、ソースへ確定反映する
// (ftester api apply-heal)。ftester-gui/AppModel.applyHealFixes / removeFromHealCache と
// 同じロジック(FTCore.HealFixApplier に切り出し済み)を使う。
// stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。ApiCommands.swift と同じ流儀)。

import ArgumentParser
import Foundation
import FTCore

struct ApiApplyHeal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply-heal",
        abstract: "自己修復の修復候補(stdin の JSON)をシナリオソースへ確定反映し、ヒール"
            + "キャッシュから該当キーを削除する(結果は 1 行 JSON で stdout に出力。診断は stderr のみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        guard let packageRoot = ScenarioHost.packageRoot() else {
            throw ValidationError("リポジトリルートを特定できません(リポジトリ内で実行してください)")
        }

        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let input: ApiApplyHealInput
        do {
            input = try JSONDecoder().decode(ApiApplyHealInput.self, from: stdinData)
        } catch {
            throw ValidationError("stdin の JSON を解析できません: \(error.localizedDescription)")
        }

        let fixes = input.fixes.map {
            HealFixInput(scenarioID: $0.scenarioID, file: $0.file, line: $0.line,
                        oldSelector: $0.oldSelector, newSelector: $0.newSelector,
                        newComment: $0.newComment)
        }

        var appliedAll: [HealFixInput] = []
        var failures: [HealFixFailure] = []
        let byFile = Dictionary(grouping: fixes, by: \.file)

        for (file, fileFixes) in byFile {
            let url = file.hasPrefix("/")
                ? URL(fileURLWithPath: file) : packageRoot.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                for fix in fileFixes {
                    failures.append(HealFixFailure(id: fix.id, message: "ファイルを読み込めません"))
                }
                continue
            }
            let result = HealFixApplier.apply(fixes: fileFixes, toSource: source)
            failures += result.failures
            guard !result.applied.isEmpty else { continue }
            do {
                try result.source.write(to: url, atomically: true, encoding: .utf8)
                appliedAll += result.applied
            } catch {
                for fix in result.applied {
                    failures.append(HealFixFailure(
                        id: fix.id,
                        message: "書き込みに失敗しました(\(error.localizedDescription))"))
                }
            }
        }

        if !appliedAll.isEmpty {
            removeFromHealCache(appliedAll.map(\.id), project: testProject)
        }

        let output = ApiApplyHealOutput(
            applied: appliedAll.map(\.id),
            failures: failures.map { ApiApplyHealFailureOutput(id: $0.id, message: $0.message) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    /// 反映済みの fix をヒールキャッシュ(.ftester/heal-cache.json)からも削除する。
    /// ファイル・キーが無ければ黙ってスキップ(GUI の AppModel.removeFromHealCache と同方針)
    private func removeFromHealCache(_ ids: [String], project: TestProject) {
        let cacheURL = project.stateDir.appendingPathComponent("heal-cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        let result = HealFixApplier.removingAppliedKeys(ids, from: dict)
        guard result.changed,
              let output = try? JSONSerialization.data(
                withJSONObject: result.dict, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? output.write(to: cacheURL, options: .atomic)
    }
}

/// stdin から読む apply-heal の入力全体
private struct ApiApplyHealInput: Decodable {
    let fixes: [ApiHealFixInputJSON]
}

/// 入力 fix 1 件分(JSON デコード用。newComment は null/省略のどちらでも nil になる)
private struct ApiHealFixInputJSON: Decodable {
    let scenarioID: String
    let file: String
    let line: Int
    let oldSelector: String
    let newSelector: String
    let newComment: String?
}

/// ftester api apply-heal の出力全体。省略可能フィールドは無い(applied/failures は常に配列)
private struct ApiApplyHealOutput: Encodable {
    let applied: [String]
    let failures: [ApiApplyHealFailureOutput]
}

private struct ApiApplyHealFailureOutput: Encodable {
    let id: String
    let message: String
}
