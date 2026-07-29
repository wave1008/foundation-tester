// VSCode拡張の「デバイスを追加」ダイアログ(モデル一覧が空のとき)から呼ばれる導入コマンド。
// 進捗は stderr の1行テキスト(拡張が OUTPUT へ流す)、結果は stdout に単発 JSON 1行。
// 実処理は CmdlineToolsInstaller。ここは入出力契約だけを持つ。

import ArgumentParser
import Foundation
import FTAndroid

struct ApiInstallCmdlineToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cmdline-tools",
        abstract: "Android SDK Command-line Tools(avdmanager)を $ANDROID_SDK/cmdline-tools/latest "
            + "へ導入する(進捗は stderr・結果は JSON で stdout)")

    func run() async throws {
        var output: ApiInstallCmdlineToolsOutput
        do {
            let result = try await CmdlineToolsInstaller.install { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            output = ApiInstallCmdlineToolsOutput(
                ok: true, alreadyInstalled: result.alreadyInstalled,
                avdmanagerPath: result.avdmanagerPath, revision: result.revision, error: nil)
        } catch {
            output = ApiInstallCmdlineToolsOutput(
                ok: false, alreadyInstalled: false, avdmanagerPath: nil, revision: "",
                error: error.localizedDescription)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(data: try encoder.encode(output), encoding: .utf8)!)
        // 失敗は非0で返す(CLI 単体で使うとき用。拡張は JSON の ok を見る)
        if !output.ok { throw ExitCode(1) }
    }
}

/// vscode-ftester/src/monitorModel.ts の InstallCmdlineToolsOutput と対。片方だけ変えない
private struct ApiInstallCmdlineToolsOutput: Encodable {
    let ok: Bool
    let alreadyInstalled: Bool
    let avdmanagerPath: String?
    let revision: String
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case ok, alreadyInstalled, avdmanagerPath, revision, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(alreadyInstalled, forKey: .alreadyInstalled)
        try container.encode(avdmanagerPath, forKey: .avdmanagerPath)
        try container.encode(revision, forKey: .revision)
        try container.encode(error, forKey: .error)
    }
}
