// VSCode拡張のライブ操作タブの記録機能向け(ftester api gen-scenario)。--steps の一時 JSON
// (録画した操作列)を FlowStep 列として読み込み、FM でシナリオ名を付けて Swift シナリオを生成する。
// NDJSON 契約: genStarted(任意) → scenarioGenerated | error。ScenarioCodeGen.writeValidated の
// ビルド検証失敗(隔離)を含め、いかなるエラーも error イベントを出して exit 0 とする
// (ApiExploreCommand.swift の非致命扱い方針と同じ。TS 側は event フィールドで分岐する契約)。

import ArgumentParser
import Foundation
import FTAgent
import FTCore
import FTDSL

struct ApiGenScenarioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gen-scenario",
        abstract: "記録した操作(--steps の一時 JSON)から Swift シナリオを生成し、NDJSON"
            + "(genStarted → scenarioGenerated | error)で stdout に流す(診断は stderr のみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(name: .customLong("steps"), help: "記録した操作を書き出した一時 JSON ファイルのパス")
    var stepsPath: String

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(ApiExploreCommand.swift と同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)

        emitLine(ApiGenScenarioStartedEvent())

        let testProject: TestProject
        do {
            testProject = try ScenarioHost.project(named: project)
        } catch {
            emitError(error.localizedDescription)
            return
        }

        let recorded: RecordedSteps
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: stepsPath))
            recorded = try JSONDecoder().decode(RecordedSteps.self, from: data)
        } catch {
            emitError("記録ファイルの読み込みに失敗しました: \(error.localizedDescription)")
            return
        }

        let summary = recorded.steps.map(\.summary).joined(separator: " / ")
        let naming = await ScenarioNamer.suggest(summary: summary, appName: recorded.app)
        // クラス名=FM のシンプル名(画面名など)/ @Test=FM の操作内容要約。FM 不可用時は
        // クラス名を既定名・@Test を記録要約(summary)へフォールバックする
        let classBaseName = naming?.name ?? "記録シナリオ"
        let testDescription = naming?.description ?? summary

        // render() は flow.name を @Test(...) に入れる。クラス名は classBaseName から別途生成する
        let flow = Flow(name: testDescription, app: recorded.app, platform: recorded.platform,
                        goal: nil, generatedBy: "ftester record v0.1", steps: recorded.steps)

        let className = ScenarioCodeGen.suggestedClassName(
            fromName: classBaseName,
            existing: ScenarioCodeGen.existingClassNames(in: [testProject.scenariosDir]))
        let code = ScenarioCodeGen.render(
            flow: flow, className: className, generatedBy: "ftester record v0.1")

        do {
            let fileURL = try ScenarioCodeGen.writeValidated(
                code: code, className: className, dir: testProject.scenariosDir,
                quarantineDir: testProject.disabledDir, project: testProject)
            emitLine(ApiGenScenarioGeneratedEvent(file: fileURL.path, className: className))
        } catch let error as ScenarioCodeGen.CodeGenError {
            logStderr("⚠️ 生成コードのビルド検証に失敗したため隔離しました: \(error.localizedDescription)")
            emitError(error.localizedDescription)
        } catch {
            emitError("シナリオの書き込みに失敗しました: \(error.localizedDescription)")
        }
    }

    private func emitError(_ message: String) {
        emitLine(ApiGenScenarioErrorEvent(message: message))
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// --steps の一時 JSON の形。TS 側(録画)が書き出す契約。steps は FlowStep の Codable キーに
/// そのまま一致させる(action/assert/locator/fallbacks/text/direction/expected/timeout/
/// maxSwipes/optional/note。Sources/FTCore/Flow.swift 参照)
private struct RecordedSteps: Decodable {
    let app: String
    let platform: String
    let steps: [FlowStep]
}

// MARK: - JSON イベント

private struct ApiGenScenarioStartedEvent: Encodable {
    let event = "genStarted"
}

private struct ApiGenScenarioGeneratedEvent: Encodable {
    let event = "scenarioGenerated"
    let file: String
    let className: String
}

private struct ApiGenScenarioErrorEvent: Encodable {
    let event = "error"
    let message: String
}
