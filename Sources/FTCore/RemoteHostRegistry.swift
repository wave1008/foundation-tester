// RemoteHostRegistry.swift
// `--host` の論理名登録簿(LocalConfig.remoteHosts。docs/remote-runner.md §13)。
// ssh/ファイル I/O はここに置かない(呼び出し側 = Sources/fleetest/RemoteCommands.swift の
// RemoteHostResolver)。ここは名前の妥当性・解決規則・並び順だけを扱う純粋関数。

import Foundation

/// 登録簿の1エントリ。**マシン名 → ssh 実体の対応だけ**を持つ。
/// 機械の身元は ssh の宛先が保証するので、リモートのマシン登録名は持たない
/// (ProfileResolver.determineMachine)
public struct RemoteHostEntry: Codable, Equatable, Sendable {
    /// マシン名(利用者が設定タブで付ける名前)。登録簿内で一意(upsert が同名を置き換える)。
    /// プロファイルの `machine` 欄・`--host` に書くのはこの名前。
    /// **JSON キーは "machine"**(2026-08-26 改名)。旧キー "name" も読む
    public let machine: String
    /// ssh 宛先("user@host" または "host")
    public let host: String
    /// ベースディレクトリ。nil なら CLI 既定("~/fleetest-runner")
    public let dir: String?

    public init(machine: String, host: String, dir: String? = nil) {
        self.machine = machine
        self.host = host
        self.dir = dir
    }

    private enum CodingKeys: String, CodingKey { case machine, name, host, dir }

    /// 読みは machine > 旧 name、書きは machine だけ(改名の互換はこの1箇所)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let machine = try container.decodeIfPresent(String.self, forKey: .machine) {
            self.machine = machine
        } else {
            self.machine = try container.decode(String.self, forKey: .name)
        }
        host = try container.decode(String.self, forKey: .host)
        dir = try container.decodeIfPresent(String.self, forKey: .dir)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machine, forKey: .machine)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(dir, forKey: .dir)
    }
}

public enum RemoteHostRegistryError: Error, LocalizedError {
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let detail):
            return "invalid host name: \(detail)"
        }
    }
}

/// `--host` に渡された生文字列の解決結果
public enum RemoteHostResolution: Equatable {
    /// 登録簿に同名があった
    case registered(RemoteHostEntry)
    /// 登録簿に無いので生の ssh 宛先として扱う
    case rawTarget(String)
    /// "local"・空文字(予約名。docs/remote-runner.md §13「フリート定義」)
    case reserved
}

public enum RemoteHostRegistry {

    /// 登録名として使える文字は英数字と `_ . -` のみ。大文字小文字は区別する
    /// (machines プロファイル名と同じ規律)
    private static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

    /// 登録簿への登録名として妥当か("local"・空文字は予約名として拒否)。
    /// `--host` に渡された文字列の解決は resolve(_:entries:) を使う(reserved は throw しない)
    public static func validateName(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteHostRegistryError.invalidName("must not be empty")
        }
        guard trimmed != "local" else {
            throw RemoteHostRegistryError.invalidName(
                "\"local\" is reserved for local execution (docs/remote-runner.md §13)")
        }
        guard trimmed.unicodeScalars.allSatisfy(allowedNameCharacters.contains) else {
            throw RemoteHostRegistryError.invalidName(
                "only letters, digits, and _ . - are allowed: \"\(raw)\"")
        }
    }

    /// **machine を省略したときの既定名**: ssh 宛先からホスト部を採る(`user@` を落とす)。
    /// マシン名はこの Mac だけのエイリアスなので、名前を付けたくない利用者に付けさせない
    /// (登録簿の鍵は host。docs/remote-runner.md §0)。
    /// **同期相手: vscode-fleetest/src/remoteRunArgs.ts の defaultMachineForHost**
    /// (拡張は入力欄のウォーターマークと送信値に使う。規則が割れると、画面が予告した名前と
    /// 実際に登録される名前が食い違う。remoteHostDefaultMachineSync.test.mjs が検出)
    public static func defaultMachine(forHost host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else { return trimmed }
        return String(trimmed[trimmed.index(after: at)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `--host <raw>` の解決。**登録簿が優先**(同名の登録があれば raw を ssh 宛先として
    /// 解釈し直さない)。"local"・空文字は登録簿を見るまでもなく reserved
    public static func resolve(_ raw: String, entries: [RemoteHostEntry]) -> RemoteHostResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "local" else { return .reserved }
        if let entry = entries.first(where: { $0.machine == trimmed }) {
            return .registered(entry)
        }
        return .rawTarget(trimmed)
    }

    /// 同名は置き換え、無ければ追加。マシン名順で安定に並べる(出力が実行のたびに揺れない)
    public static func upsert(_ entry: RemoteHostEntry, into entries: [RemoteHostEntry]) -> [RemoteHostEntry] {
        var result = entries.filter { $0.machine != entry.machine }
        result.append(entry)
        return result.sorted { $0.machine < $1.machine }
    }

    public static func remove(machine: String, from entries: [RemoteHostEntry]) -> [RemoteHostEntry] {
        entries.filter { $0.machine != machine }
    }

    /// 同じ ssh 宛先を指す登録が複数あるとき、その宛先を返す(名前順。§13 のガードの土台
    /// — 同一リモートへの二重ディスパッチはデバイスの取り合いになる)
    public static func duplicateTargets(_ entries: [RemoteHostEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.host, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map(\.key).sorted()
    }
}
