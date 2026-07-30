// テスト設計の元資料(Projects/<name>/docs/testbases/*.md)から Swift シナリオの**下書き**を作る。
// 生成物は @Deleted 付き = 一括実行の対象外(セレクタが TODO のままなので当然落ちる)。
// 構造化は FM(TestbaseDrafter)→ 失敗時は決定的パーサ(TestbaseOutline.parse)へフォールバックする。

import ArgumentParser
import Foundation
import FTAgent
import FTCore
import FTDSL

struct DraftScenarioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft-scenario",
        abstract: "Generate a scenario draft from a test base (docs/testbases/*.md)")

    @Option(help: "Test project name (defaults to the only one in Projects/, or the default project)")
    var project: String?

    @Option(help: "Path to the test base file (defaults to the only file in the project docs/testbases/)")
    var testbase: String?

    @Option(help: "Name of the generated test class (defaults to one derived from the test base heading)")
    var name: String?

    @Option(help: "Bundle ID of the app under test (defaults to the value from the app profile)")
    var app: String?

    @Option(help: "Target platform: ios / android (defaults to both)")
    var platform: String?

    @Flag(help: "Structure the draft from the Markdown headings and bullets alone, without Foundation Models")
    var noFm = false

    @Flag(help: "Print the generated code to stdout instead of writing a file")
    var dryRun = false

    func run() async throws {
        if let platform, !["ios", "android"].contains(platform) {
            throw ValidationError("platform は ios / android のいずれかです: \(platform)")
        }
        let testProject = try ScenarioHost.project(named: project)
        let source = try resolveTestbase(in: testProject)
        let markdown = try String(contentsOf: source, encoding: .utf8)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("テストベースが空です: \(source.path)")
        }
        let fallbackTitle = source.deletingPathExtension().lastPathComponent

        var draft: ScenarioDraft?
        if !noFm {
            if markdown.count > TestbaseDrafter.maxInputCharacters {
                print("⚠️ テストベースが長いため先頭 \(TestbaseDrafter.maxInputCharacters) 文字だけを FM に渡します"
                      + "(残りは下書きに反映されません。分割するか --no-fm を使ってください)")
            }
            draft = await TestbaseDrafter.draft(markdown: markdown, fallbackTitle: fallbackTitle)
            if draft == nil {
                print("⚠️ Foundation Models で構造化できなかったため、見出し・箇条書きから機械的に組み立てます")
            }
        }
        let outline = draft ?? TestbaseOutline.parse(markdown: markdown, fallbackTitle: fallbackTitle)

        let bundleID = try resolveApp(in: testProject)
        let className = ScenarioCodeGen.suggestedClassName(
            fromName: name ?? outline.title,
            existing: name == nil
                ? ScenarioCodeGen.existingClassNames(in: [testProject.scenariosDir]) : [])
        let code = ScenarioDraftCodeGen.render(
            draft: outline, className: className, app: bundleID, platform: platform,
            source: source.lastPathComponent, generatedBy: "ftester draft-scenario")

        if dryRun {
            print(code)
            return
        }
        let dir = testProject.scenariosDir.appendingPathComponent("Drafts")
        // --name 明示時は重複回避の連番が付かない = 既存ファイルを黙って上書きしうるので止める
        let target = dir.appendingPathComponent("\(className).swift")
        if FileManager.default.fileExists(atPath: target.path) {
            throw ValidationError("同名の下書きが既にあります: \(target.path)"
                                  + "(--name で別名にするか、既存を消してください)")
        }
        let url = try ScenarioCodeGen.writeValidated(
            code: code, className: className, dir: dir,
            quarantineDir: testProject.disabledDir, project: testProject)
        print("✅ 下書きを生成しました: \(url.path)")
        print("   scene \(outline.scenes.count) 件 / セレクタは \(ScenarioDraftCodeGen.placeholder) のまま")
        print("   次: 実機で ft_snapshot して実セレクタに置き換え → クラスの @Deleted を外す")
    }

    /// --testbase 明示 > docs/testbases/ に 1 ファイル > 候補を並べてエラー
    private func resolveTestbase(in project: TestProject) throws -> URL {
        if let testbase {
            let url = URL(fileURLWithPath: (testbase as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("テストベースが見つかりません: \(url.path)")
            }
            return url
        }
        let candidates = TestbaseOutline.candidates(in: project.testbasesDir)
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty {
            throw ValidationError("テストベースがありません: \(project.testbasesDir.path)"
                                  + "(--testbase でパスを指定することもできます)")
        }
        let list = candidates.map { "  - \($0.lastPathComponent)" }.joined(separator: "\n")
        throw ValidationError("テストベースが複数あります。--testbase で選んでください:\n\(list)")
    }

    /// --app 明示 > アプリプロファイル(指定 platform → ios → android の順で最初に見つかった bundle ID)
    private func resolveApp(in project: TestProject) throws -> String {
        if let app { return app }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: project.appsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? JSONDecoder().decode(AppProfile.self, from: data) else { continue }
            for candidate in [platform, "ios", "android"].compactMap({ $0 }) {
                if let bundleID = profile.section(for: candidate).app, !bundleID.isEmpty {
                    return bundleID
                }
            }
        }
        throw ValidationError("対象アプリを特定できません。--app で bundle ID を指定するか、"
                              + "\(project.appsDir.path) にアプリプロファイルを用意してください")
    }
}
