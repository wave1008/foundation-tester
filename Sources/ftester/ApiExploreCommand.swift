// VSCode拡張等向け機械可読CLI(ftester api explore)。FMエージェントによるアプリ探索→Swift
// シナリオ生成(FTester.swift の Explore コマンドと同フロー)を NDJSON(1行1イベント)で
// stdout に流す: exploreStarted/exploreStep/exploreValidating/exploreFinished/error 以外は
// 出さない(診断は stderr)。
//
// エラー方針: FM利用不可・ドライバ接続不可・書き込みの予期しない失敗は {"kind":"error",...} を
// 出し exit 1。ScenarioCodeGen.writeValidated がビルド検証失敗で _disabled/ へ隔離した場合は
// 致命的扱いにせず exploreFinished(quarantined:true, file に隔離先パス)で exit 0 とする。
// 探索の outcome(completed/gaveUp/stepLimitReached)はいずれもシナリオ生成に至るため
// exploreFinished で正常終了する。

import ArgumentParser
import Foundation
import FTAgent
import FTCore
import FTDSL

struct ApiExploreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explore",
        abstract: "FM エージェントがアプリを探索して Swift シナリオを生成する過程を NDJSON"
            + "(exploreStarted → exploreStep×N → exploreValidating → exploreFinished)で"
            + "stdout に流す(診断は stderr のみ。致命的な失敗は error イベントを出して exit 1)")

    @Option(help: "対象アプリの bundle identifier")
    var bundle: String

    @Option(help: "テストの目標(自然言語)")
    var goal: String

    @Option(name: .customLong("max-steps"), help: "探索ステップ数の上限")
    var maxSteps: Int = 25

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "シナリオの生成先ディレクトリ(省略時: Projects/<name>/Scenarios/Generated)")
    var out: String?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(ApiRunCommand.swift と同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)

        let fm = FMDoctor.check()
        guard fm.available else {
            emitError(fm.detail)
            throw ExitCode(1)
        }

        let testProject: TestProject
        do {
            testProject = try ScenarioHost.project(named: project)
        } catch {
            emitError(error.localizedDescription)
            throw ExitCode(1)
        }

        let driver: AppDriver
        do {
            driver = try driverOptions.makeDriver()
            _ = try await driver.status()  // 接続不能なら早期に分かりやすく失敗させる
        } catch {
            emitError("ドライバへの接続に失敗しました: \(error.localizedDescription)")
            throw ExitCode(1)
        }

        emitLine(ApiExploreStartedEvent(
            project: testProject.name, bundleID: bundle, goal: goal,
            maxSteps: maxSteps, platform: driverOptions.platform))

        let agent = ExplorerAgent(driver: driver, goal: goal, maxSteps: maxSteps)
        agent.onStep = { step, description in
            self.emitLine(ApiExploreStepEvent(
                step: step, maxSteps: self.maxSteps, description: description))
        }

        let result: ExplorerAgent.Result
        do {
            result = try await agent.explore(bundleID: bundle)
        } catch {
            emitError("探索に失敗しました: \(error.localizedDescription)")
            throw ExitCode(1)
        }

        var flow = result.flow
        flow.platform = driverOptions.platform  // 実行時のドライバ自動選択に使う

        let dir = out.map { URL(fileURLWithPath: $0) } ?? testProject.generatedDir
        let quarantineDir = testProject.disabledDir
        let className = ScenarioCodeGen.suggestedClassName(
            for: flow,
            existing: ScenarioCodeGen.existingClassNames(
                in: [testProject.scenariosDir, dir, quarantineDir]))
        let code = ScenarioCodeGen.render(
            flow: flow, className: className,
            generatedBy: "ftester api explore v0.1 (apple-fm-on-device)")

        emitLine(ApiExploreValidatingEvent(message: "生成コードをビルド検証中"))

        var fileURL: URL
        var quarantined = false
        do {
            fileURL = try ScenarioCodeGen.writeValidated(
                code: code, className: className, dir: dir,
                quarantineDir: quarantineDir, project: testProject)
        } catch ScenarioCodeGen.CodeGenError.buildFailed(let quarantinedURL, let detail) {
            // 致命的扱いにせず quarantined:true で exploreFinished を通常どおり出す(ヘッダ参照)
            fileURL = quarantinedURL
            quarantined = true
            logStderr("⚠️ 生成コードのビルド検証に失敗したため隔離しました: \(detail)")
        } catch {
            emitError("シナリオの書き込みに失敗しました: \(error.localizedDescription)")
            throw ExitCode(1)
        }

        let scenarioID = "\(className).\(ScenarioCodeGen.methodName(1))"
        emitLine(ApiExploreFinishedEvent(
            outcome: outcomeString(result.outcome), detail: outcomeDetail(result.outcome),
            stepsTaken: result.stepsTaken, file: fileURL.path, scenarioID: scenarioID,
            quarantined: quarantined))
    }

    private func outcomeString(_ outcome: ExplorerAgent.Outcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case .gaveUp: return "gaveUp"
        case .stepLimitReached: return "stepLimitReached"
        }
    }

    private func outcomeDetail(_ outcome: ExplorerAgent.Outcome) -> String? {
        switch outcome {
        case .completed(let description):
            return (description?.isEmpty == false) ? description : nil
        case .gaveUp(let reason):
            return reason
        case .stepLimitReached:
            return nil
        }
    }

    private func emitError(_ message: String) {
        emitLine(ApiExploreErrorEvent(message: message))
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

// MARK: - JSON イベント

/// ftester api explore の冒頭イベント
private struct ApiExploreStartedEvent: Encodable {
    let kind = "exploreStarted"
    let project: String
    let bundleID: String
    let goal: String
    let maxSteps: Int
    let platform: String
}

/// ExplorerAgent.onStep 1 回ごとのイベント(計画提示は step:0 で届く)
private struct ApiExploreStepEvent: Encodable {
    let kind = "exploreStep"
    let step: Int
    let maxSteps: Int
    let description: String
}

/// 生成コードのビルド検証を開始する直前に 1 回だけ出すイベント
private struct ApiExploreValidatingEvent: Encodable {
    let kind = "exploreValidating"
    let message: String
}

/// ftester api explore の末尾イベント(正常系。省略可能なフィールドは JSON 上で "null" を
/// 明示する。ApiScenarioInfo(ApiCommands.swift)と同方針で encodeIfPresent(キー省略)は使わない)
private struct ApiExploreFinishedEvent: Encodable {
    let outcome: String
    let detail: String?
    let stepsTaken: Int
    let file: String?
    let scenarioID: String?
    let quarantined: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, outcome, detail, stepsTaken, file, scenarioID, quarantined
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("exploreFinished", forKey: .kind)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(detail, forKey: .detail)
        try container.encode(stepsTaken, forKey: .stepsTaken)
        try container.encode(file, forKey: .file)
        try container.encode(scenarioID, forKey: .scenarioID)
        try container.encode(quarantined, forKey: .quarantined)
    }
}

/// 致命的な失敗(FM 利用不可・ドライバ接続不可・シナリオ書き込みの予期しない失敗等)を
/// 示すイベント。このイベントで終わる場合のみ exit code 1
private struct ApiExploreErrorEvent: Encodable {
    let kind = "error"
    let message: String
}
