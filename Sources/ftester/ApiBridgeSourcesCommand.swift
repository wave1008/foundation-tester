// `ftester api bridge-sources`: ブリッジ実装の入力集合を出す(一覧 or 1行の digest)。
// 実体と同期規律は Sources/FTCore/BridgeSourceSet.swift(一覧を2箇所に書かないための唯一の定義元)。
//
// 呼び出し側は `Scripts/e2e.sh` で、in-app ブリッジの入力が
// 「最後に --ios-inapp を通した状態」から動いていないかを見るのに使う。
// デバイスにもプロジェクトにも触らない。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

struct ApiBridgeSourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge-sources",
        abstract: "Print the input files of a bridge implementation, or a single digest of them."
            + " Touches no device")

    @Option(help: "Which bridge: inapp / xcuitest / android")
    var set: String = "inapp"

    @Flag(help: "Print one digest line instead of the file list")
    var digest = false

    func run() async throws {
        // 綴りは CLI 向けの語(inapp)で受け、内部の case 名(inApp)へ寄せる
        let normalized = set.lowercased() == "inapp" ? "inApp" : set
        guard let sourceSet = BridgeSourceSet(rawValue: normalized) else {
            throw ValidationError("unknown --set \(set)"
                + " (expected one of: inapp, xcuitest, android)")
        }
        let root = try RepoRoot.find()
        if digest {
            print(try sourceSet.digest(repoRoot: root))
        } else {
            try sourceSet.files(repoRoot: root).forEach { print($0) }
        }
    }
}
