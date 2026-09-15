// VSCode拡張向け: 自己修復の修復候補を stdin から受け取り、ソースへ確定反映する
// (fleetest api apply-heal)。確定反映のロジックは FTCore.HealFixApplier に切り出し済みで、
// このコマンドは stdin/stdout の橋渡しだけを担う。
// stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。ApiCommands.swift と同じ流儀)。

import ArgumentParser
import Foundation
import FTCore

struct ApiApplyHeal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply-heal",
        abstract: "Apply a self-heal candidate (JSON on stdin) to the scenario source for good"
            + " (result as one line of JSON on stdout; diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    func run() async throws {
        // プロジェクト名の検証だけ(存在しない名前はここで断る)
        _ = try ScenarioHost.project(named: project)
        guard let packageRoot = ScenarioHost.packageRoot() else {
            throw ValidationError("cannot determine the repository root (run this inside the repository)")
        }

        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let input: ApiApplyHealInput
        do {
            input = try JSONDecoder().decode(ApiApplyHealInput.self, from: stdinData)
        } catch {
            throw ValidationError("cannot parse the JSON on stdin: \(error.localizedDescription)")
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
                    failures.append(HealFixFailure(id: fix.id, message: "cannot read the file"))
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
                        message: "failed to write (\(error.localizedDescription))"))
                }
            }
        }

        let output = ApiApplyHealOutput(
            applied: appliedAll.map(\.id),
            failures: failures.map { ApiApplyHealFailureOutput(id: $0.id, message: $0.message) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        ConsoleOut.out(String(data: data, encoding: .utf8)!)
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

/// fleetest api apply-heal の出力全体。省略可能フィールドは無い(applied/failures は常に配列)
private struct ApiApplyHealOutput: Encodable {
    let applied: [String]
    let failures: [ApiApplyHealFailureOutput]
}

private struct ApiApplyHealFailureOutput: Encodable {
    let id: String
    let message: String
}
