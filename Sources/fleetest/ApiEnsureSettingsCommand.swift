// 受け手パッケージの `.claude/settings.json` の Bash 許可リストを補修する
// (fleetest api ensure-settings)。install.sh が**毎回**呼ぶ。
//
// なぜ独立したコマンドが要るか: 許可リストは従来 `fleetest init` でしか書かれず、更新は
// `--skip-project`(init を回さない)で走るため、**許可エントリを増やしても既存の受け手には
// 一生届かなかった**。エントリの実装は ProjectScaffold.writeClaudeSettings ただ1つに保つ。

import ArgumentParser
import Foundation
import FTCore

struct ApiEnsureSettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ensure-settings",
        abstract: "Top up the fleetest-related Bash permissions in the consumer package .claude/settings.json (idempotent)")

    @Option(help: "Root of the consumer package (where TestProjects/ lives; defaults to the current directory)")
    var workDir: String?

    @Option(help: "Location of the foundation-tester clone (used for the absolute paths of the allowed commands)")
    var toolRoot: String?

    func run() async throws {
        let root = URL(fileURLWithPath: workDir ?? FileManager.default.currentDirectoryPath)
        // **Codex だけの受け手には .claude/ を作らない**。承認の粗さは approval_policy /
        // sandbox_mode の話で、コマンド単位の allowlist は Codex に存在しない
        // (AgentIntegration.hasCommandPermissionAllowlist)
        let agents = AgentIntegration.detect(packageRoot: root)
        guard agents.contains(where: \.hasCommandPermissionAllowlist) else {
            print("skipped: no agent with a per-command permission allowlist "
                  + "(\(agents.map(\.displayName).joined(separator: ", ")))")
            return
        }
        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: toolRoot)
        // 画面に出るのは呼び出し元(install.sh)の1行だけなので短く。中身は settings.json にある
        if added.isEmpty {
            print(".claude/settings.json is up to date (nothing added)")
        } else {
            print("Added \(added.count) entrie(s) (.claude/settings.json)")
        }
    }
}
