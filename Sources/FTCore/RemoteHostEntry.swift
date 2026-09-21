// RemoteHostEntry.swift
// LocalConfig.remoteHosts の1エントリ(登録簿ファイルのスキーマ)。解決規則・並び順は
// FTRemote/RemoteHostRegistry.swift。FTCore に置くのは LocalConfig(FTCore)がこの型を持つため。

import Foundation

/// 登録簿の1エントリ。**マシン名 → ssh 実体の対応だけ**を持つ。
/// 機械の身元は ssh の宛先が保証するので、リモートのマシン登録名は持たない
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
    /// 設定タブのバッジ色(`MachineBadgeColor.palette` の鍵)。**唯一の決定点は
    /// `RemoteHostRegistry.upsert`**(新規は自動割り当て・省略は既存を保つ)
    public let color: String?
    /// 設定タブの「マシン有効」。**false だけを保存する**(nil = 有効。true は upsert が nil へ畳む)。
    /// false のマシンへはプロファイル駆動の振り分けで配らない(判定は `MachineEnablement`)。
    /// **唯一の決定点は `RemoteHostRegistry.upsert`**(nil は既存を保つ)
    public let enabled: Bool?
    /// この機械で使う Xcode の pin(`.app` バンドルの絶対パス。例 "/Applications/Xcode_27.app"。
    /// 利用者向けの案内と同じ形 = docs/remote-runner-setup.md の `--developer-dir` の例)。
    /// 実際に export する `DEVELOPER_DIR` は `FTRemote.XcodeSelection.resolve` がここから
    /// "/Contents/Developer" を補って作る。nil ならディスパッチが指紋照合で自動選択する。
    /// **存在確認はしない** —— 誤った pin は後段の toolchain 照合が blocking で捕まえる
    /// (docs/remote-runner.md §7)。
    /// **`fmConcurrency` と同じ規律**: upsert はここを素通しするだけで、「省略したら既存を保つ・
    /// 消すのは明示操作だけ」は呼び出し側(`remote machines add` の --clear-developer-dir、
    /// `ApiRemoteHostsCommand.mergingDeveloperDir`)が持つ
    public let developerDir: String?

    public init(machine: String, host: String, dir: String? = nil, fmConcurrency: Int? = nil,
                color: String? = nil, enabled: Bool? = nil, developerDir: String? = nil) {
        self.machine = machine
        self.host = host
        self.dir = dir
        self.fmConcurrency = fmConcurrency
        self.color = color
        self.enabled = enabled
        self.developerDir = developerDir
    }

    public var isEnabled: Bool { enabled != false }

    private enum CodingKeys: String, CodingKey {
        case machine, name, host, dir, fmConcurrency, color, enabled, developerDir
    }

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
        // パレットに無い鍵・空文字は nil へ倒す(壊れた設定で止めない。fmConcurrency と同じ方針)
        let rawColor = try container.decodeIfPresent(String.self, forKey: .color)
        color = (rawColor.map { !$0.isEmpty && MachineBadgeColor.isKnown($0) } ?? false) ? rawColor : nil
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        // 空文字は未設定へ倒す(dir/color と同じ方針。手書き設定で "" を書いても壊れた pin にしない)
        let rawDeveloperDir = try container.decodeIfPresent(String.self, forKey: .developerDir)
        developerDir = (rawDeveloperDir?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machine, forKey: .machine)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(dir, forKey: .dir)
        try container.encodeIfPresent(fmConcurrency, forKey: .fmConcurrency)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(developerDir, forKey: .developerDir)
    }
}
