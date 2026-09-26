// 対話セッション(MCP / ライブ操作)が操作している台の印。RunLease の姉妹型(置き場所 `.fleetest/`・
// 鍵 = iOS はシミュレータ UDID / Android は adb serial も同じ)。書き手: MCPServer.call(台を指す
// ツールが通るたびに上書き)・ApiLiveServe(コマンドが通るたびに上書き)。どちらも終了時に自分の印を消す。
// 読み手: run の台の絞り込み(ProfileRunner.limitingDevicesAvoidingMCP)・台を止める操作の門
// (DeviceBooter.deviceInUseRefusal / sweepRefusal)・別の対話セッション(writeAndWarnIfInUse)。
// 死んだ印の掃除は BridgeProvisioner.sweepStaleLeases。
// **ファイル名接頭辞は `mcp-` のまま・書き手を区別しない**(読み手を増やさないため——ライブ操作が
// 保持者でも警告文は「another MCP session」のまま。保持者の pid から実プロセス名を引き分ける
// 実装コストに見合わないので、ライブ操作も同じ「対話セッション」の一種として扱う簡易化であって誤りではない)。
// **生死は「pid + そのプロセスの開始時刻」で見る(時間の閾値を置かない)** —— run はこの印を「避ける」だけで断らない
// (ユーザー決定「避けて、足りなければ警告して使う」)ので、使い終わった後も対話セッションが生きている間は残る印の損は
// 「その台を避ける」に収まる。閾値を置くと考え中のエージェントの台を run が奪う形が戻る。
// 開始時刻まで見るのは、保持者が消えた後に同じ pid が別のプロセスへ再利用されると、印が生き返って台を避け続けるため。
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

import FTCore
import Foundation

public enum MCPDeviceLease {
    static let prefix = "mcp-"
    static let suffix = ".lease"
    private static let pidSeparator: Character = "@"

    public static func leaseURL(stateDir: URL, key: String, pid: Int32) -> URL {
        stateDir.appendingPathComponent("\(prefix)\(key)\(pidSeparator)\(pid)\(suffix)")
    }

    /// `<pid> <開始時刻 epoch 秒>`。ベストエフォート(失敗は無視。印が書けないだけで MCP の操作は止めない)
    public static func write(stateDir: URL, key: String, pid: Int32) {
        guard let started = ProcessLiveness.startTime(pid) else { return }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? "\(pid) \(Int(started.timeIntervalSince1970))"
            .write(to: leaseURL(stateDir: stateDir, key: key, pid: pid), atomically: true, encoding: .utf8)
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
    static func holder(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 2, let pid = Int32(fields[0]), pid > 0, let recorded = Int(fields[1]),
              ProcessLiveness.isAlive(pid), let started = ProcessLiveness.startTime(pid),
              Int(started.timeIntervalSince1970) == recorded else { return nil }
        return pid
    }

    /// stateDir 内の全 lease ファイルから、ファイル名の pid と中身の pid が一致する生きている
    /// (鍵, pid) の組を集める(`excluding` は除く)。`holderPID`/`liveHolders` の共有実装 ——
    /// ファイル名の pid だけを信じて中身を読まないと、手で書き換えられた/壊れたファイルを拾う
    private static func liveEntries(stateDir: URL, excluding: Set<Int32>) -> [(key: String, pid: Int32)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return [] }
        return names.compactMap { name in
            guard let parsed = parse(fileName: name), !excluding.contains(parsed.pid),
                  holder(at: stateDir.appendingPathComponent(name)) == parsed.pid else { return nil }
            return parsed
        }
    }

    /// 1つの鍵の生きている保持者(`excluding` の pid なら nil)。同じ鍵を複数の対話セッションが
    /// 同時に持つことがあるが、この API は1件しか返せないので**最小 pid** を返す(呼び手は
    /// 「使用中か」と代表の pid しか見ないので、どれを選んでも意味は変わらない)。
    /// 台を止める操作の門(DeviceBooter)が使う
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

    /// 印を書き、その台を run か**別の対話セッション**(pid 別。MCP でもライブ操作でも区別しない)が
    /// 今使用中なら警告文を返す(`MCPServer.markDeviceInUse` / `ApiLiveServe` / ft_run_scenario の
    /// 共通口。断らない = run の衝突と同じ扱い)。write は自分の (key, pid) のファイルしか触らない
    /// ので、書いてから読んでも他人の印を消さない。**deviceKey は呼び手が解決済みの UDID/serial を
    /// そのまま渡す**
    public static func writeAndWarnIfInUse(stateDir: URL, key: String, pid: Int32) -> String? {
        write(stateDir: stateDir, key: key, pid: pid)
        if let holder = RunLease.holderPID(stateDir: stateDir, key: key), holder != pid {
            return "⚠️ a fleetest run (pid \(holder)) is using this device right now — what you do here and what"
                + " the run does interfere with each other (screens, input, app state)."
                + " Wait for the run to finish, or drive another device."
        }
        guard let otherSession = holderPID(stateDir: stateDir, key: key, excluding: [pid]) else { return nil }
        // 相手がライブ操作でも文言は変えない(ファイル冒頭の注記参照——「MCP session」のまま)
        return "⚠️ another MCP session (pid \(otherSession)) is driving this device too — the two"
            + " sessions move each other's screens, so refs and snapshots go stale under you."
            + " Drive another device, or finish one of the sessions."
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
