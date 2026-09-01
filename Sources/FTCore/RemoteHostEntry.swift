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
    /// この機械での FM 呼び出しの同時実行枠。nil ならランナー側の既定(`FMLock.defaultConcurrency`)。
    /// **機械によっては 2 並列以上で FM が壊れる**(実測と経緯は docs/remote-runner.md)。
    /// ディスパッチが `FT_FM_CONCURRENCY` として運ぶ(FTRemote/RemoteDispatch.remoteRunCommand)
    public let fmConcurrency: Int?

    public init(machine: String, host: String, dir: String? = nil, fmConcurrency: Int? = nil) {
        self.machine = machine
        self.host = host
        self.dir = dir
        self.fmConcurrency = fmConcurrency
    }

    private enum CodingKeys: String, CodingKey { case machine, name, host, dir, fmConcurrency }

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
        // 不正値(0 以下)は nil へ倒す。**壊れた設定で run を止めるより既定で動かす**
        // —— この欄は性能・安定性の調整であって、実行の可否を決める設定ではない
        let slots = try container.decodeIfPresent(Int.self, forKey: .fmConcurrency)
        fmConcurrency = (slots ?? 0) > 0 ? slots : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machine, forKey: .machine)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(dir, forKey: .dir)
        try container.encodeIfPresent(fmConcurrency, forKey: .fmConcurrency)
    }
}
