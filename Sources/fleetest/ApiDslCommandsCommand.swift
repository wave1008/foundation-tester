// `fleetest api dsl-commands`: DSL コマンドの索引を JSON で出す。
// 表の実体と同期規律は Sources/FTCore/CommandIndex.swift(`CommandIndexSyncTests` が守る)。
// デバイスにもプロジェクトにも触らないので、シナリオ生成の前に何度でも呼べる。

import ArgumentParser
import FTCore
import Foundation

struct ApiDslCommandsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dsl-commands",
        abstract: "Print the Swift DSL command index as JSON on stdout"
            + " (name, category, signature, summary, chainable, origin). Touches no device")

    @Option(help: ArgumentHelp("Only the commands of one category ("
        + DSLCommandIndex.categories.joined(separator: "/") + "/project)"))
    var category: String?

    @Option(help: "Only the command with this exact name")
    var name: String?

    @Option(help: ArgumentHelp("Also scan this project's scenarios/ for @FTCommand-marked helper functions"
        + " and list them with origin: \"project\". Without --project only the built-in commands are listed"))
    var project: String?

    func run() async throws {
        var commands = DSLCommandIndex.all
        if let category {
            commands = commands.filter { $0.category == category }
        }
        if let name {
            commands = commands.filter { $0.name == name }
        }

        var projectCommands: [ProjectCommandEntry] = []
        var warnings: [String] = []
        var resolvedProjectName: String?
        if let project {
            let resolved = try ScenarioHost.project(named: project)
            resolvedProjectName = resolved.name
            let scan = ProjectCommandIndex.scan(project: resolved)
            projectCommands = scan.commands
            warnings = scan.warnings
        }
        if let category, category != "project" {
            projectCommands = []
        }
        if let name {
            projectCommands = projectCommands.filter { $0.name == name }
        }

        let entries = commands.map { DSLCommandJSONEntry(builtin: $0) }
            + projectCommands.map { DSLCommandJSONEntry(project: $0) }
        var categories = Set(DSLCommandIndex.all.map(\.category))
        if !projectCommands.isEmpty { categories.insert("project") }

        let output = Output(
            count: entries.count,
            // 索引に無い名前は**存在しない**(コンパイルエラーになる)ことを呼び出し側に伝える
            categories: categories.sorted(),
            chainOnly: DSLCommandIndex.chainOnlyNames.sorted(),
            project: resolvedProjectName,
            commands: entries,
            warnings: warnings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        ConsoleOut.out(String(data: try encoder.encode(output), encoding: .utf8)!)
    }

    private struct Output: Encodable {
        let count: Int
        let categories: [String]
        /// exist(...) の戻り値にしか生えないメソッド(自由関数としては存在しない)
        let chainOnly: [String]
        /// --project を渡したときだけ載る(解決できたプロジェクト名)
        let project: String?
        let commands: [DSLCommandJSONEntry]
        /// project 走査の警告(private・組み込みとの名前衝突など)。--project 省略時は常に空
        let warnings: [String]
    }
}

/// builtin(CommandIndex)と project(ProjectCommandIndex)を1つの JSON 形へ揃える。
/// `origin` は必須(呼び出し側が「これはコード生成が保証する組み込みか、プロジェクトが
/// 書いた実物か」を区別できるようにする)。file/line/receiver は project origin のときだけ載る
/// (Encodable 合成の Optional は nil のとき欄ごと省かれる)
private struct DSLCommandJSONEntry: Encodable {
    let name: String
    let category: String
    let signature: String
    let summary: String
    let chainable: Bool
    let origin: String
    let file: String?
    let line: Int?
    let receiver: String?

    init(builtin: DSLCommandInfo) {
        name = builtin.name
        category = builtin.category
        signature = builtin.signature
        summary = builtin.summary
        chainable = builtin.chainable
        origin = "builtin"
        file = nil
        line = nil
        receiver = nil
    }

    init(project entry: ProjectCommandEntry) {
        name = entry.name
        category = "project"
        signature = entry.signature
        summary = entry.summary
        // builtin の chainable は「FTElement のメソッド」と同義(CommandIndex の先頭コメント)。
        // MCP の ft_dsl_commands も receiver を見て select(...). を付けるので同じ判定に揃える
        chainable = entry.receiver == "FTElement"
        origin = "project"
        file = entry.file
        line = entry.line
        receiver = entry.receiver
    }
}
