// VSCode拡張向け: マシン登録簿(LocalConfig.remoteHosts)の読み書き(fleetest api remote-machines)。
// docs/remote-runner.md §13。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。
// ApiCommands.swift と同じ流儀)。
//
// **拡張側と1:1の契約**: dir/machine は未設定でも常にキー自体は出し、値は空文字にする
// (拡張側で undefined 判定を書かせない。ApiScenarioInfo 等の「省略可能フィールドは null を
// 明示する」規律の空文字版 — この API は VSCode 設定 `fleetest.remote.hosts` からの移行元にもなるため、
// 移行スクリプトが持つ JSON 形とキー集合を合わせておく)。

import ArgumentParser
import Foundation
import FTCore
import FTRemote

struct ApiRemoteHostsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-machines",
        abstract: "Read or update the machine registry (~/.config/fleetest/config.json) and print it as JSON"
            + " on stdout (diagnostics on stderr only; docs/remote-runner.md §13)")

    @Option(name: .customLong("import"),
            // ArgumentHelp は文字列リテラルからしか作れない(連結した String は渡せない)
            help: ArgumentHelp("Upsert these entries (JSON array: [{\"machine\":…,\"host\":…,\"dir\":…}]), "
                + "then print the resulting registry. For migrating from the VSCode setting fleetest.remote.hosts"))
    var importJSON: String?

    @Option(help: "Remove this entry by machine name, then print the resulting registry")
    var remove: String?

    func run() async throws {
        if importJSON != nil && remove != nil {
            throw ValidationError("--import and --remove cannot be combined")
        }

        var config = LocalConfig.load()
        if let importJSON {
            let incoming = try Self.decodeImportEntries(importJSON)
            for raw in incoming {
                // **"local" は登録簿に入れない**(予約名)。設定タブの固定行から来る FM 枠と「マシン有効」だけを
                // LocalConfig へ流す。host は表示用なので無視する
                if (raw.machine ?? "").trimmingCharacters(in: .whitespaces) == "local" {
                    config.fmConcurrency = (raw.fmConcurrency ?? 0) > 0 ? raw.fmConcurrency : nil
                    // キーが無ければ据え置く(登録簿の行と同じ規律)。保存するのは false だけ
                    if let enabled = raw.enabled {
                        config.localMachineEnabled = enabled ? nil : false
                    }
                    continue
                }
                try Self.validateColor(raw.color)
                let entry = raw.entry
                try RemoteHostRegistry.validateName(entry.machine)
                _ = try RemoteHostSpec.parse(entry.host)
                if let dir = entry.dir { try RemoteLayout.validateBase(dir) }
                try RemoteHostRegistry.validateUniqueHost(entry, in: config.remoteHosts ?? [])
                var merged = Self.mergingFMConcurrency(entry, sentKey: raw.fmConcurrency != nil,
                                                       from: config.remoteHosts ?? [])
                merged = Self.mergingDeveloperDir(merged, sentKey: raw.developerDir != nil,
                                                  from: config.remoteHosts ?? [])
                config.remoteHosts = RemoteHostRegistry.upsert(merged, into: config.remoteHosts ?? [])
            }
            try config.save()
        } else if let name = remove {
            config.remoteHosts = RemoteHostRegistry.remove(machine: name, from: config.remoteHosts ?? [])
            try config.save()
        }

        Self.emit(config.remoteHosts ?? [])
    }

    /// **空文字は未設定として扱う**: この API の出力自体が dir/machine を "" で埋める契約
    /// (キー省略を書かせない)なので、`--import` にその出力をそのまま渡す移行元(拡張)を
    /// 想定すると "" が「未設定」として往復する必要がある。`RemoteHostEntry` の `dir`/`machine`
    /// を素の Optional のまま "" で埋めると、読み手が空文字を「その名前が指定されている」と読む
    /// FM 枠の合流。**キーを送ってきたクライアントの指定が勝ち、送ってこなければ既存値を保つ**。
    /// 設定タブは常に送る(空欄 = 0 = 解除)ので指定が効き、キーを持たない古い/別のクライアントが
    /// upsert しても**機械ごとの枠が黙って消えない**(upsert は丸ごと置き換えるため)。
    /// テストのために純粋関数へ出してある —— run() の中に埋めると検証がロジックの再実装になる
    static func mergingFMConcurrency(_ entry: RemoteHostEntry, sentKey: Bool,
                                     from existing: [RemoteHostEntry]) -> RemoteHostEntry {
        guard !sentKey else { return entry }
        let kept = existing.first { $0.machine == entry.machine }?.fmConcurrency
        return RemoteHostEntry(machine: entry.machine, host: entry.host,
                               dir: entry.dir, fmConcurrency: kept, color: entry.color,
                               enabled: entry.enabled, developerDir: entry.developerDir)
    }

    /// developerDir(Xcode の pin)の合流。**mergingFMConcurrency と同じ規律**: `sentKey` は
    /// クライアントが JSON にこのキー自体を送ってきたか(値が "" でも key はある = 明示的に消したい)。
    /// 送ってこなければ(旧い/別のクライアント)既存の pin を保つ ―― upsert 自身は素通しなので、
    /// ここで保たないと developerDir を知らないクライアントの import のたびに pin が消える
    static func mergingDeveloperDir(_ entry: RemoteHostEntry, sentKey: Bool,
                                    from existing: [RemoteHostEntry]) -> RemoteHostEntry {
        guard !sentKey else { return entry }
        let kept = existing.first { $0.machine == entry.machine }?.developerDir
        return RemoteHostEntry(machine: entry.machine, host: entry.host,
                               dir: entry.dir, fmConcurrency: entry.fmConcurrency, color: entry.color,
                               enabled: entry.enabled, developerDir: kept)
    }

    /// 非空で未知の色は `--import` 全体を拒否する(既知の鍵一覧をメッセージに出す)。
    /// "" と欠落(nil)は通す(upsert が保つ/割り当てる)
    static func validateColor(_ raw: String?) throws {
        guard let raw, !raw.isEmpty else { return }
        guard MachineBadgeColor.isKnown(raw) else {
            let known = MachineBadgeColor.palette.map(\.key).joined(separator: ", ")
            throw ValidationError("unknown machine badge color \"\(raw)\" (known: \(known))")
        }
    }

    static func decodeImport(_ json: String) throws -> [RemoteHostEntry] {
        try decodeImportEntries(json).map(\.entry)
    }

    /// 生の import エントリ。**`fmConcurrency` のキーを送ってきたかを合流が見る**ので、
    /// `RemoteHostEntry` へ畳む前の姿が要る(畳むと「キー無し」と「0」の区別が消える)
    static func decodeImportEntries(_ json: String) throws -> [ApiRemoteHostImportEntry] {
        guard let data = json.data(using: .utf8) else {
            throw ValidationError("--import is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode([ApiRemoteHostImportEntry].self, from: data)
        } catch {
            throw ValidationError("--import is not a valid JSON array of host entries: \(error.localizedDescription)")
        }
    }

    /// **登録簿の JSON はこの1形だけ**(`remote machines list --json` も同じ口を通す。以前は
    /// `{"machines":[…]}` の別形を持っていて、拡張が読む契約と食い違っていた = §18 の残件)
    static func emit(_ entries: [RemoteHostEntry]) {
        let config = LocalConfig.load()
        let output = ApiRemoteHostsOutput(
            hosts: entries.map(ApiRemoteHostEntry.init),
            defaultFMConcurrency: FMLock.defaultConcurrency,
            local: ApiLocalEntry(host: "\(NSUserName())@localhost",
                                 fmConcurrency: config.fmConcurrency ?? 0,
                                 enabled: config.localMachineEnabled != false),
            machineColors: MachineBadgeColor.palette.map { ApiMachineColor(key: $0.key, color: $0.hex) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(output), let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }
}

/// `--import` のデコード用(ApiRemoteHostEntry の逆向き)。dir は "" もキー省略も未設定として
/// 受け取る。鍵は machine(拡張は machine で送る)。
///
/// **machine は省略可**(キー欠落・空文字とも)。無いときは host のホスト部を名前にする
/// (RemoteHostRegistry.defaultMachine)。マシン名はこの Mac だけのエイリアスなので、
/// 名前を付けたくない利用者に付けさせない
struct ApiRemoteHostImportEntry: Decodable {
    let machine: String?
    let host: String
    let dir: String?
    /// FM 並列枠。**キーの有無を区別する** —— 設定タブは常に送る(空欄 = 0 = 解除)ので
    /// 0 を「解除」として扱う必要があり、キーごと無い場合(他のクライアント)は既存値を保つ。
    /// nil = キーが無い / 0 以下 = 解除 / 正の値 = その枠数
    let fmConcurrency: Int?
    /// バッジ色の鍵。"" と欠落は未設定(upsert が保つ/割り当てる)。非空の未知鍵は
    /// `validateColor` が --import 全体を拒否するので、ここに来る時点で既知か未設定
    let color: String?
    /// 「マシン有効」。欠落 = 既存を保つ(upsert が決める)。設定タブは常に送る
    let enabled: Bool?
    /// Xcode の pin。**キーの有無を区別する**(mergingDeveloperDir が読む) ——
    /// キーが無ければ(developerDir を知らないクライアント)既存の pin を保つ。
    /// "" は「明示的に pin を外したい」(dir/color と違い、こちらは常に消去の意味に倒す ——
    /// 「空文字は既存を保つ」にすると、この API からは pin を一度外すと二度と消せなくなる)
    let developerDir: String?

    var entry: RemoteHostEntry {
        let given = (machine ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = given.isEmpty ? RemoteHostRegistry.defaultMachine(forHost: host) : given
        return RemoteHostEntry(machine: resolved, host: host,
                               dir: dir.flatMap { $0.isEmpty ? nil : $0 },
                               fmConcurrency: fmConcurrency.flatMap { $0 > 0 ? $0 : nil },
                               color: color.flatMap { $0.isEmpty ? nil : $0 },
                               enabled: enabled,
                               developerDir: developerDir.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// dir は常にキーを出し、未設定は空文字("")にする(nil にはしない。契約はファイル冒頭のコメント)。
/// **マシン名のキーは "machine"**
private struct ApiRemoteHostEntry: Encodable {
    let machine: String
    let host: String
    let dir: String
    /// dir と同じ流儀で**常にキーを出す**。未設定は 0(dir の "" に相当) —— 設定タブが
    /// 空欄として描けるようにするため。null は使わない(ファイル冒頭の契約)
    let fmConcurrency: Int
    /// dir と同じ流儀で常にキーを出す。未設定は ""(パレットに無い鍵は decode 時点で nil に落ちる)
    let color: String
    /// 「マシン有効」。常にキーを出す(未設定 = true)
    let enabled: Bool
    /// Xcode の pin。dir と同じ流儀で常にキーを出す。未設定は ""
    let developerDir: String

    init(_ entry: RemoteHostEntry) {
        machine = entry.machine
        host = entry.host
        dir = entry.dir ?? ""
        fmConcurrency = entry.fmConcurrency ?? 0
        color = entry.color ?? ""
        enabled = entry.isEnabled
        developerDir = entry.developerDir ?? ""
    }
}

private struct ApiRemoteHostsOutput: Encodable {
    let hosts: [ApiRemoteHostEntry]
    /// 未設定のときに効く枠数。**この値を拡張へ運ぶのは定数の二重管理を避けるため** ——
    /// 唯一の定義元は `FMLock.defaultConcurrency` で、GUI はウォーターマークに実値を出す
    let defaultFMConcurrency: Int
    /// **この機械**の行(設定タブが消せない固定行として出す)。登録簿には入らない ——
    /// "local" は予約名で、値は `LocalConfig.fmConcurrency` に置く。
    /// host は表示用に組み立てた文字列で、ssh には使わない
    let local: ApiLocalEntry
    /// バッジ色パレット(パレット順)。**拡張はパレットを持たない**
    /// (定数の二重管理を避ける。唯一の定義元は MachineBadgeColor)
    let machineColors: [ApiMachineColor]
}

private struct ApiMachineColor: Encodable {
    let key: String
    let color: String
}

/// 設定タブの固定行。編集できるのは fmConcurrency と enabled だけ(host/machine は表示専用)
private struct ApiLocalEntry: Encodable {
    let machine = "local"
    let host: String
    let fmConcurrency: Int
    let enabled: Bool
}
