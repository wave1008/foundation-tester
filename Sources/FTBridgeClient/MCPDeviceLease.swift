// 対話セッション(MCP / ライブ操作)が操作しているデバイスの印。RunLease の姉妹型(置き場所 `.fleetest/`・
// 鍵 = iOS はシミュレータ UDID / Android は adb serial も同じ)。書き手: MCPServer.call(デバイスを指す
// ツールが通るたびに上書き)・ApiLiveServe(コマンドが通るたびに上書き)。どちらも終了時に自分の印を消す。
// 読み手: run のデバイスの絞り込み(ProfileRunner.limitingDevicesAvoidingMCP)・デバイスを止める操作の門
// (DeviceBooter.deviceInUseRefusal / sweepRefusal)・別の対話セッション(writeAndWarnIfInUse / writeLiveAndWarnIfInUse)。
// 死んだ印の掃除は BridgeProvisioner.sweepStaleLeases。
// **ファイル名接頭辞は `mcp-` のまま・ファイル名で書き手を区別しない**(読み手を増やさないため。
// 書き手の種類は中身で分ける = 末尾の「中身は2形」)。
// **生死は「pid + そのプロセスの開始時刻」で見る(時間の閾値を置かない)** —— run はこの印を「避ける」だけで断らない
// (ユーザー決定「避けて、足りなければ警告して使う」)ので、使い終わった後も対話セッションが生きている間は残る印の損は
// 「そのデバイスを避ける」に収まる。閾値を置くと考え中のエージェントのデバイスを run が奪う形が戻る。
// 開始時刻まで見るのは、保持者が消えた後に同じ pid が別のプロセスへ再利用されると、印が生き返ってデバイスを避け続けるため。
//
// **ファイルは「鍵 × pid」ごとに1つ**(`mcp-<鍵>@<pid>.lease`)。1台を複数の対話セッションが
// 同時に触るのは正常(避けて・警告して使う、が両者の言い分)なので、1台1ファイルにすると後から
// 触ったセッションが先のセッションの印を上書きし、自分の終了処理(removeAll)がファイルごと
// 消して先の生きた保持者を消してしまう。書き手は自分の (鍵, pid) のファイルしか触らないので、
// 他人の印を上書き・削除できない。**`@` を区切りに使えるのは鍵(UDID / adb serial)が `@` を
// 含まないから**(UDID は16進+ハイフン、adb serial は英数字・`:`(TCP接続)・`-` のみ)。
// 含み得る形が増えたら区切りを見直す。**旧形式(`mcp-<鍵>.lease`、`@` 無し)の互換読みはしない**
// (parse が nil を返すだけで無視される。掃除(isLeaseFile + holder(at:))はファイル名の形に
// 依存しないので、死んだ旧形式の印はこれまでどおり掃除される)
//
// **中身は2形**: MCP = `<pid> <開始時刻>` / ライブ操作 = `<pid> <開始時刻> live <最後に操作した epoch ミリ秒。未操作は 0>`。
// 読み手(holder(at:) 経由の門・run の回避)は両形を区別せず「使用中」と数える(見ているだけのライブ操作でも
// デバイスを止めさせない = B5)。区別するのは対話セッション同士の警告だけ —— モニターでデバイスを選ぶだけで
// ライブ操作は起動直後から印を書くので、それを「駆動している」と警告すると、AIアシスタントの作業を見ているだけで
// 「どちらかのセッションを終えよ」と促していた。**ライブ操作への警告は「自分の前回の印以降に、相手が実際に操作した」
// ときだけ**(ref が古くなるのはその事象そのもの。時間の閾値を置かない)。前回の印 = 自分のファイルの mtime

import FTCore
import Foundation

public enum MCPDeviceLease {
    static let prefix = "mcp-"
    static let suffix = ".lease"
    private static let pidSeparator: Character = "@"

    public static func leaseURL(stateDir: URL, key: String, pid: Int32) -> URL {
        stateDir.appendingPathComponent("\(prefix)\(key)\(pidSeparator)\(pid)\(suffix)")
    }

    private static let liveMarker = "live"

    /// 書き手の種類。`.live` は最後に操作した時刻(未操作は nil)を持つ
    public enum Role: Equatable {
        case mcp
        case live(lastAction: Date?)
    }

    /// `<pid> <開始時刻 epoch 秒>`(MCP の形)。ベストエフォート(失敗は無視。印が書けないだけで MCP の操作は止めない)
    public static func write(stateDir: URL, key: String, pid: Int32) {
        write(stateDir: stateDir, key: key, pid: pid, role: .mcp)
    }

    static func write(stateDir: URL, key: String, pid: Int32, role: Role) {
        guard let started = ProcessLiveness.startTime(pid) else { return }
        var text = "\(pid) \(Int(started.timeIntervalSince1970))"
        if case .live(let lastAction) = role {
            text += " \(liveMarker) \(lastAction.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)"
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? text.write(to: leaseURL(stateDir: stateDir, key: key, pid: pid), atomically: true, encoding: .utf8)
    }

    static func isLeaseFile(_ name: String) -> Bool { name.hasPrefix(prefix) && name.hasSuffix(suffix) }

    /// ファイル名 `mcp-<key>@<pid>.lease` を分解する。区切りが無い(旧形式・壊れたファイル名)は nil
    static func parse(fileName: String) -> (key: String, pid: Int32)? {
        guard isLeaseFile(fileName) else { return nil }
        let core = fileName.dropFirst(prefix.count).dropLast(suffix.count)
        guard let sep = core.lastIndex(of: pidSeparator), let pid = Int32(core[core.index(after: sep)...])
        else { return nil }
        let key = String(core[core.startIndex..<sep])
        return key.isEmpty ? nil : (key, pid)
    }

    /// 印のファイル1つの保持者(生きていて開始時刻も一致するときだけ)。それ以外は nil
    static func holder(at url: URL) -> Int32? { record(at: url)?.pid }

    /// 中身を読み、保持者が生きているときだけ (pid, 種類) を返す。2形以外の中身は nil
    static func record(at url: URL) -> (pid: Int32, role: Role)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let role: Role
        switch fields.count {
        case 2: role = .mcp
        case 4:
            guard fields[2] == liveMarker, let millis = Int64(fields[3]), millis >= 0 else { return nil }
            role = .live(lastAction: millis == 0 ? nil : Date(timeIntervalSince1970: Double(millis) / 1000))
        default: return nil
        }
        guard let pid = Int32(fields[0]), pid > 0, let recorded = Int(fields[1]),
              ProcessLiveness.isAlive(pid), let started = ProcessLiveness.startTime(pid),
              Int(started.timeIntervalSince1970) == recorded else { return nil }
        return (pid, role)
    }

    /// stateDir 内の全 lease ファイルから、ファイル名の pid と中身の pid が一致する生きている
    /// (鍵, pid, 種類) の組を集める(`excluding` は除く)。`holderPID`/`liveHolders` の共有実装 ——
    /// ファイル名の pid だけを信じて中身を読まないと、手で書き換えられた/壊れたファイルを拾う
    private static func liveEntries(stateDir: URL, excluding: Set<Int32>)
        -> [(key: String, pid: Int32, role: Role)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return [] }
        return names.compactMap { name in
            guard let parsed = parse(fileName: name), !excluding.contains(parsed.pid),
                  let record = record(at: stateDir.appendingPathComponent(name)), record.pid == parsed.pid
            else { return nil }
            return (parsed.key, parsed.pid, record.role)
        }
    }

    /// 1つの鍵の生きている保持者(`excluding` の pid なら nil)。同じ鍵を複数の対話セッションが
    /// 同時に持つことがあるが、この API は1件しか返せないので**最小 pid** を返す(呼び手は
    /// 「使用中か」と代表の pid しか見ないので、どれを選んでも意味は変わらない)。
    /// デバイスを止める操作の門(DeviceBooter)が使う
    public static func holderPID(stateDir: URL, key: String, excluding: Set<Int32>) -> Int32? {
        liveEntries(stateDir: stateDir, excluding: excluding)
            .filter { $0.key == key }.map { $0.pid }.min()
    }

    /// 生きている保持者の一覧(鍵 → pid)。`excluding` の pid が持つ印は数えない(自分・親)。
    /// 同じ鍵に複数の生きた保持者が居ても代表(最小 pid)しか返さない(holderPID と同じ理由)
    public static func liveHolders(stateDir: URL, excluding: Set<Int32>) -> [String: Int32] {
        var holders: [String: Int32] = [:]
        for entry in liveEntries(stateDir: stateDir, excluding: excluding) {
            if let existing = holders[entry.key], existing <= entry.pid { continue }
            holders[entry.key] = entry.pid
        }
        return holders
    }

    /// MCP の印を書き、そのデバイスを run か別の対話セッションが今使用中なら警告文を返す
    /// (`MCPServer.markDeviceInUse` / ft_run_scenario の共通口。断らない = run の衝突と同じ扱い)。
    /// write は自分の (key, pid) のファイルしか触らないので、書いてから読んでも他人の印を消さない。
    /// **deviceKey は呼び手が解決済みの UDID/serial をそのまま渡す**
    public static func writeAndWarnIfInUse(stateDir: URL, key: String, pid: Int32) -> String? {
        let previousMark = markDate(stateDir: stateDir, key: key, pid: pid)
        write(stateDir: stateDir, key: key, pid: pid, role: .mcp)
        return warning(stateDir: stateDir, key: key, pid: pid, previousMark: previousMark,
                       warnsAboutSessions: true)
    }

    /// ライブ操作の印を書き、警告文を返す(`LiveDeviceLease.refresh`)。`acting` = このコマンドがデバイスを
    /// 操作する(自動の画面更新・観測は false)。最後に操作した時刻は自分の印から引き継ぐ。
    /// **対話セッションへの警告は操作するコマンドでだけ出す**(見ているだけなら相手の画面を動かさない)。
    /// run の警告は従来どおり毎回
    public static func writeLiveAndWarnIfInUse(stateDir: URL, key: String, pid: Int32, acting: Bool,
                                               now: Date = Date()) -> String? {
        let url = leaseURL(stateDir: stateDir, key: key, pid: pid)
        let previousMark = markDate(stateDir: stateDir, key: key, pid: pid)
        let carried: Date?
        if case .live(let lastAction)? = record(at: url)?.role { carried = lastAction } else { carried = nil }
        write(stateDir: stateDir, key: key, pid: pid, role: .live(lastAction: acting ? now : carried))
        return warning(stateDir: stateDir, key: key, pid: pid, previousMark: previousMark,
                       warnsAboutSessions: acting)
    }

    /// 自分の印を前回書いた時刻(ファイルの mtime)。無ければ nil
    private static func markDate(stateDir: URL, key: String, pid: Int32) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: leaseURL(stateDir: stateDir, key: key, pid: pid).path))?[
            .modificationDate] as? Date
    }

    /// 警告の判定。MCP の相手は居るだけで警告する。ライブ操作の相手は「自分の前回の印より後に操作した」
    /// ときだけ(前回の印が無い = このデバイスで初めての呼び出しは、古くなる ref をまだ持っていないので黙る)
    private static func warning(stateDir: URL, key: String, pid: Int32, previousMark: Date?,
                                warnsAboutSessions: Bool) -> String? {
        if let holder = RunLease.holderPID(stateDir: stateDir, key: key), holder != pid {
            return "⚠️ a fleetest run (pid \(holder)) is using this device right now — what you do here and what"
                + " the run does interfere with each other (screens, input, app state)."
                + " Wait for the run to finish, or drive another device."
        }
        guard warnsAboutSessions else { return nil }
        let others = liveEntries(stateDir: stateDir, excluding: [pid]).filter { $0.key == key }
        if let otherSession = others.filter({ $0.role == .mcp }).map(\.pid).min() {
            return "⚠️ another MCP session (pid \(otherSession)) is driving this device too — the two"
                + " sessions move each other's screens, so refs and snapshots go stale under you."
                + " Drive another device, or finish one of the sessions."
        }
        guard let previousMark else { return nil }
        let operated = others.filter {
            if case .live(let lastAction?) = $0.role { return lastAction > previousMark }
            return false
        }
        guard let live = operated.map(\.pid).min() else { return nil }
        return "⚠️ the monitor's live control (pid \(live)) operated this device since your previous call —"
            + " refs and snapshots taken before that may be stale. Take a fresh snapshot before acting on them."
    }

    /// その pid が持つ印を全部消す(MCP / ライブ操作の終了時)。**ファイル名の pid で選ぶ**
    /// (中身を読まない)ので、他人の (鍵, pid) のファイルは対象にならない
    public static func removeAll(stateDir: URL, pid: Int32) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return }
        for name in names {
            guard let parsed = parse(fileName: name), parsed.pid == pid else { continue }
            try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name))
        }
    }
}
