// RemoteHostEntry.swift
// LocalConfig.remoteHosts の1エントリ(登録簿ファイルのスキーマ)。解決規則・並び順は
// FTRemote/RemoteHostRegistry.swift。FTCore に置くのは LocalConfig(FTCore)がこの型を持つため。

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
