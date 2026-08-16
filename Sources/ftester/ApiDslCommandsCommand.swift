// `ftester api dsl-commands`: DSL コマンドの索引を JSON で出す。
// 表の実体と同期規律は Sources/FTCore/CommandIndex.swift(`CommandIndexSyncTests` が守る)。
// デバイスにもプロジェクトにも触らないので、シナリオ生成の前に何度でも呼べる。

import ArgumentParser
import FTCore
import Foundation

struct ApiDslCommandsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dsl-commands",
        abstract: "Print the Swift DSL command index as JSON on stdout"
            + " (name, category, signature, summary, chainable). Touches no device")

    @Option(help: "Only the commands of one category (structure/operation/scroll/flick/existence/text/value/app/control/this)")
    var category: String?

    @Option(help: "Only the command with this exact name")
    var name: String?

    func run() async throws {
        var commands = DSLCommandIndex.all
        if let category {
            commands = commands.filter { $0.category == category }
        }
        if let name {
            commands = commands.filter { $0.name == name }
        }
        let output = Output(
            count: commands.count,
            // 索引に無い名前は**存在しない**(コンパイルエラーになる)ことを呼び出し側に伝える
            categories: Array(Set(DSLCommandIndex.all.map(\.category))).sorted(),
            chainOnly: DSLCommandIndex.chainOnlyNames.sorted(),
            commands: commands)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(data: try encoder.encode(output), encoding: .utf8)!)
    }

    private struct Output: Encodable {
        let count: Int
        let categories: [String]
        /// exist(...) の戻り値にしか生えないメソッド(自由関数としては存在しない)
        let chainOnly: [String]
        let commands: [DSLCommandInfo]
    }
}
