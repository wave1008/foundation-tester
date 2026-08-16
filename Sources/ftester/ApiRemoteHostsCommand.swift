// VSCode拡張向け: `--host` 登録簿(LocalConfig.remoteHosts)の読み書き(ftester api remote-hosts)。
// docs/remote-runner.md §13。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。
// ApiCommands.swift と同じ流儀)。
//
// **拡張側と1:1の契約**: dir/machine は未設定でも常にキー自体は出し、値は空文字にする
// (拡張側で undefined 判定を書かせない。ApiScenarioInfo 等の「省略可能フィールドは null を
// 明示する」規律の空文字版 — この API は VSCode 設定 `ftester.remote.hosts` からの移行元にもなるため、
// 移行スクリプトが持つ JSON 形とキー集合を合わせておく)。

import ArgumentParser
import Foundation
import FTCore

struct ApiRemoteHostsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-hosts",
        abstract: "Read or update the --host registry (~/.config/ftester/config.json) and print it as JSON"
            + " on stdout (diagnostics on stderr only; docs/remote-runner.md §13)")

    @Option(name: .customLong("import"),
            // ArgumentHelp は文字列リテラルからしか作れない(連結した String は渡せない)
            help: ArgumentHelp("Upsert these entries (JSON array: [{\"name\":…,\"host\":…,\"dir\":…,\"machine\":…}]), "
                + "then print the resulting registry. For migrating from the VSCode setting ftester.remote.hosts"))
    var importJSON: String?

    @Option(help: "Remove this entry by name, then print the resulting registry")
    var remove: String?

    func run() async throws {
        if importJSON != nil && remove != nil {
            throw ValidationError("--import and --remove cannot be combined")
        }

        var config = LocalConfig.load()
        if let importJSON {
            let incoming = try Self.decodeImport(importJSON)
            for entry in incoming {
                try RemoteHostRegistry.validateName(entry.name)
                _ = try RemoteHostSpec.parse(entry.host)
                if let dir = entry.dir { try RemoteLayout.validateBase(dir) }
                config.remoteHosts = RemoteHostRegistry.upsert(entry, into: config.remoteHosts ?? [])
            }
            try config.save()
        } else if let name = remove {
            config.remoteHosts = RemoteHostRegistry.remove(name: name, from: config.remoteHosts ?? [])
            try config.save()
        }

        Self.emit(config.remoteHosts ?? [])
    }

    /// **空文字は未設定として扱う**: この API の出力自体が dir/machine を "" で埋める契約
    /// (キー省略を書かせない)なので、`--import` にその出力をそのまま渡す移行元(拡張)を
    /// 想定すると "" が「未設定」として往復する必要がある。`RemoteHostEntry` の `dir`/`machine`
    /// を素の Optional のまま "" で埋めると、RemoteCompat.mismatches の machineName 照合が
    /// 空文字を「マシン名 "" を期待している」と読んで誤って fail-closed になる
    private static func decodeImport(_ json: String) throws -> [RemoteHostEntry] {
        guard let data = json.data(using: .utf8) else {
            throw ValidationError("--import is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode([ApiRemoteHostImportEntry].self, from: data).map(\.entry)
        } catch {
            throw ValidationError("--import is not a valid JSON array of host entries: \(error.localizedDescription)")
        }
    }

    private static func emit(_ entries: [RemoteHostEntry]) {
        let output = ApiRemoteHostsOutput(hosts: entries.map(ApiRemoteHostEntry.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(output), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }
}

/// `--import` のデコード用(ApiRemoteHostEntry の逆向き)。dir は "" もキー省略も未設定として
/// 受け取る。**machine は 2026-08-17 に廃止**(未知キーとして黙って無視される = 古い設定でも壊れない)
private struct ApiRemoteHostImportEntry: Decodable {
    let name: String
    let host: String
    let dir: String?

    var entry: RemoteHostEntry {
        RemoteHostEntry(name: name, host: host, dir: dir.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// dir は常にキーを出し、未設定は空文字("")にする(nil にはしない。契約はファイル冒頭のコメント)
private struct ApiRemoteHostEntry: Encodable {
    let name: String
    let host: String
    let dir: String

    init(_ entry: RemoteHostEntry) {
        name = entry.name
        host = entry.host
        dir = entry.dir ?? ""
    }
}

private struct ApiRemoteHostsOutput: Encodable {
    let hosts: [ApiRemoteHostEntry]
}
