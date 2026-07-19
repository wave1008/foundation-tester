// VSCode拡張の起動時プレフライト向け: プロトコル版(FTCore.ftesterProtocolVersion)を1行JSONで
// stdout に出力する(ftester api version)。診断メッセージは無い(stderr にも何も出さない)。
// 対向: vscode-ftester/src/compatCheck.ts。

import ArgumentParser
import Foundation
import FTCore

struct ApiVersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "プロトコル版を {\"protocol\": <版>} の JSON で stdout に出力する")

    func run() async throws {
        let output = ApiVersionOutput(protocol: ftesterProtocolVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }
}

private struct ApiVersionOutput: Encodable {
    let `protocol`: Int
}
