// VSCode拡張等の外部ツール向け機械可読 CLI(ftester api ...)。
// stdout には 1 行の JSON だけを出力し、進捗・警告等の診断メッセージは stderr に出す
// (stdout をパースする外部ツールを汚さないため)。

import ArgumentParser
import Foundation
import FTCore
import FTDSL

struct ApiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "VSCode拡張等の外部ツール向け機械可読 API(stdout に JSON を出力)",
        subcommands: [ApiListScenarios.self, ApiSteps.self, ApiRunCommand.self,
                      ApiMonitorCommand.self, ApiApplyHeal.self, ApiListDevices.self,
                      ApiListApps.self, ApiDeviceUp.self, ApiDeviceDown.self, ApiDevicesUp.self,
                      ApiValidateProfile.self,
                      ApiLiveCommand.self, ApiExploreCommand.self,
                      ApiDeviceCatalogCommand.self, ApiCreateDeviceCommand.self,
                      ApiInstalledDevicesCommand.self, ApiHostMetricsCommand.self,
                      ApiGenScenarioCommand.self, ApiDeleteScenarioCommand.self,
                      ApiResultsCommand.self])
}

struct ApiListScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-scenarios",
        abstract: "シナリオ一覧をソース位置(ファイル・行番号)付きの JSON で stdout に出力する"
            + "(診断・警告は stderr のみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Flag(name: .customLong("skip-build"), help: "実行前の swift build をスキップする")
    var skipBuild = false

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        let repoRoot = try ftesterRepoRoot()

        if !skipBuild {
            logStderr("→ シナリオをビルド(\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
        }

        let infos = try ScenarioHost.list(project: testProject)
        let scenariosDir = testProject.scenariosDir
        let folders = ScenarioFolders.list(scenariosDir: scenariosDir)
        let classFileMap = ScenarioFolders.classFileMap(scenariosDir: scenariosDir)

        // 同一ファイルは 1 回だけ読み込む(同じクラスに複数のテストメソッドがあるため)
        var sourceCache: [URL: String] = [:]
        var scenarioOutputs: [ApiScenarioInfo] = []
        for info in infos {
            let className = Self.className(of: info.id)
            let methodName = Self.methodName(of: info.id)

            guard let sourceURL = classFileMap[className] else {
                logStderr("⚠️ シナリオのソースファイルが見つかりません: \(info.id)")
                scenarioOutputs.append(ApiScenarioInfo(
                    id: info.id, title: info.title, app: info.app, platform: info.platform,
                    deleted: info.deleted, file: nil, classLine: nil, methodLine: nil,
                    folder: nil))
                continue
            }
            let folder = ScenarioFolders.folderName(of: sourceURL, scenariosDir: scenariosDir)

            let source: String?
            if let cached = sourceCache[sourceURL] {
                source = cached
            } else if let loaded = try? String(contentsOf: sourceURL, encoding: .utf8) {
                sourceCache[sourceURL] = loaded
                source = loaded
            } else {
                logStderr("⚠️ ソースを読み込めません: \(sourceURL.path)")
                source = nil
            }

            var classLine: Int?
            var methodLine: Int?
            if let source {
                classLine = ScenarioSourceEditor.classDeclarationLine(
                    inSource: source, className: className)
                if classLine == nil {
                    logStderr("⚠️ class 宣言が見つかりません: \(className)(\(sourceURL.path))")
                }
                methodLine = ScenarioSourceEditor.methodDeclarationLine(
                    inSource: source, className: className, method: methodName)
                if methodLine == nil {
                    logStderr("⚠️ func 宣言が見つかりません: \(info.id)(\(sourceURL.path))")
                }
            }

            scenarioOutputs.append(ApiScenarioInfo(
                id: info.id, title: info.title, app: info.app, platform: info.platform,
                deleted: info.deleted, file: sourceURL.path, classLine: classLine,
                methodLine: methodLine, folder: folder))
        }

        // 空クラス(@Test を1件も持たない @TestClass)もツリーに残す。classFileMap(ソース走査)に
        // ありシナリオが1件も無いものが対象。非 @TestClass のヘルパ class は isTestClass で除外する。
        let classesWithScenarios = Set(infos.map { Self.className(of: $0.id) })
        var emptyClassOutputs: [ApiEmptyClassInfo] = []
        for (className, sourceURL) in classFileMap where !classesWithScenarios.contains(className) {
            let source: String?
            if let cached = sourceCache[sourceURL] {
                source = cached
            } else if let loaded = try? String(contentsOf: sourceURL, encoding: .utf8) {
                sourceCache[sourceURL] = loaded
                source = loaded
            } else {
                source = nil
            }
            guard let source,
                  ScenarioSourceEditor.isTestClass(inSource: source, className: className) else {
                continue
            }
            emptyClassOutputs.append(ApiEmptyClassInfo(
                className: className, file: sourceURL.path,
                classLine: ScenarioSourceEditor.classDeclarationLine(inSource: source, className: className),
                folder: ScenarioFolders.folderName(of: sourceURL, scenariosDir: scenariosDir)))
        }
        emptyClassOutputs.sort { $0.className.localizedStandardCompare($1.className) == .orderedAscending }

        let output = ApiListScenariosOutput(
            project: testProject.name, repoRoot: repoRoot.path,
            scenariosDir: scenariosDir.path, folders: folders, scenarios: scenarioOutputs,
            emptyClasses: emptyClassOutputs)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    private static func className(of id: String) -> String {
        id.firstIndex(of: ".").map { String(id[..<$0]) } ?? id
    }

    private static func methodName(of id: String) -> String {
        id.firstIndex(of: ".").map { String(id[id.index(after: $0)...]) } ?? id
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// ftester api list-scenarios の 1 シナリオ分の出力。
/// 省略可能なフィールドは JSON 上で "null" を明示する(外部ツール側でキー欠落と null を
/// 区別せず扱えるよう、synthesized Encodable の encodeIfPresent(キー省略)は使わない)
private struct ApiScenarioInfo: Encodable {
    let id: String
    let title: String
    let app: String
    let platform: String?
    let deleted: Bool
    /// クラスを定義する .swift の絶対パス(見つからなければ nil)
    let file: String?
    /// class 宣言の行番号(1 起点、解決不能なら nil)
    let classLine: Int?
    /// func 宣言の行番号(1 起点、解決不能なら nil)
    let methodLine: Int?
    /// Scenarios/ 直下のサブフォルダ名(直下ファイルは nil)
    let folder: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, app, platform, deleted, file, classLine, methodLine, folder
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(app, forKey: .app)
        try container.encode(platform, forKey: .platform)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(file, forKey: .file)
        try container.encode(classLine, forKey: .classLine)
        try container.encode(methodLine, forKey: .methodLine)
        try container.encode(folder, forKey: .folder)
    }
}

/// @Test を1件も持たない @TestClass(空クラス)。ツリーに class ノードだけ残すため出力する。
/// 対向: vscode-ftester/src/model.ts EmptyClassInfo、testTree.ts。
private struct ApiEmptyClassInfo: Encodable {
    let className: String
    let file: String
    let classLine: Int?
    let folder: String?

    private enum CodingKeys: String, CodingKey { case className, file, classLine, folder }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(className, forKey: .className)
        try container.encode(file, forKey: .file)
        try container.encode(classLine, forKey: .classLine)  // null 明示(ApiScenarioInfo と同方針)
        try container.encode(folder, forKey: .folder)
    }
}

/// ftester api list-scenarios の出力全体
private struct ApiListScenariosOutput: Encodable {
    let project: String
    let repoRoot: String
    let scenariosDir: String
    let folders: [String]
    let scenarios: [ApiScenarioInfo]
    let emptyClasses: [ApiEmptyClassInfo]
}

// MARK: - api steps

struct ApiSteps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "steps",
        abstract: "シナリオを dry-run してステップ表相当の JSON を stdout に出力する"
            + "(診断・警告は stderr のみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "対象シナリオ ID(クラス名.メソッド名)")
    var scenario: String

    @Flag(name: .customLong("skip-build"), help: "実行前の swift build をスキップする")
    var skipBuild = false

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)

        if !skipBuild {
            logStderr("→ シナリオをビルド(\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
        }

        let events = try await ScenarioHost.dryRunSteps(
            project: testProject, scenarioID: scenario)
        let rows = Self.stepRows(from: events, packageRoot: ScenarioHost.packageRoot())

        let output = ApiStepsOutput(scenario: scenario, steps: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    /// dry-run のイベント列をステップ表相当の行に変換する。
    /// コメントはソースをファイル毎に 1 回読んで行末 // を引く(読めなければ nil で続行)。
    /// file はイベントに載っているランナー相対パスをそのまま出す(変換しない。
    /// ブレークポイントキー "file:line" としてそのまま使う契約)
    private static func stepRows(from events: [ScenarioEvent],
                                 packageRoot: URL?) -> [ApiStepRow] {
        var sceneTitles: [Int: String] = [:]
        for event in events where event.kind == "sceneStarted" {
            if let scene = event.scene { sceneTitles[scene] = event.sceneTitle }
        }

        let steps = events.filter { $0.kind == "step" }
        // event.file はランナーの cwd で相対化された repo 相対パスか #file の絶対パス
        var linesByFile: [String: Set<Int>] = [:]
        for step in steps {
            if let file = step.file, let line = step.line {
                linesByFile[file, default: []].insert(line)
            }
        }
        var commentsByFile: [String: [Int: String]] = [:]
        for (file, lines) in linesByFile {
            let url = file.hasPrefix("/")
                ? URL(fileURLWithPath: file)
                : (packageRoot?.appendingPathComponent(file) ?? URL(fileURLWithPath: file))
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            commentsByFile[file] = ScenarioSourceComments.trailingComments(
                inSource: source, lines: lines)
        }

        return steps.map { step in
            let comment = step.file.flatMap { file in
                step.line.flatMap { commentsByFile[file]?[$0] }
            }
            return ApiStepRow(
                index: step.index ?? 0,
                scene: step.scene,
                sceneTitle: step.scene.flatMap { sceneTitles[$0] },
                section: step.section,
                command: step.description ?? "",
                comment: comment,
                generatedComment: comment == nil
                    ? StepDescription.describe(command: step.description ?? "") : nil,
                file: step.file,
                line: step.line)
        }
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// ftester api steps の 1 ステップ分の出力。省略可能なフィールドは JSON 上で "null" を明示する
/// (ApiScenarioInfo と同方針)
private struct ApiStepRow: Encodable {
    let index: Int
    let scene: Int?
    /// scene(n, "タイトル") のタイトル
    let sceneTitle: String?
    /// condition / action / expectation / nil(CAE 外)
    let section: String?
    /// コマンドと引数(例: tap "#login_btn||ログイン")
    let command: String
    /// ソース行末の // コメント(無ければ nil)
    let comment: String?
    /// コメントが無い行の補完用に生成した自然言語の説明(StepDescription。生成不能なら nil)
    let generatedComment: String?
    /// コマンド呼び出し元のソース位置(ブレークポイントのキー。dry-run イベント由来。変換しない)
    let file: String?
    let line: Int?

    private enum CodingKeys: String, CodingKey {
        case index, scene, sceneTitle, section, command, comment, generatedComment, file, line
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(scene, forKey: .scene)
        try container.encode(sceneTitle, forKey: .sceneTitle)
        try container.encode(section, forKey: .section)
        try container.encode(command, forKey: .command)
        try container.encode(comment, forKey: .comment)
        try container.encode(generatedComment, forKey: .generatedComment)
        try container.encode(file, forKey: .file)
        try container.encode(line, forKey: .line)
    }
}

/// ftester api steps の出力全体
private struct ApiStepsOutput: Encodable {
    let scenario: String
    let steps: [ApiStepRow]
}
