// `fleetest bridge down --all` の門(純粋関数。I/O は呼び出し側が注入する holderPID で持つ)。
// --port(単体)は `DeviceBooter.deviceInUseRefusal` をそのまま使えば足りるが、--all は
// 複数ポートをまとめて「1台でも保持者が居れば掃討ごと断る」形にする必要があるため、
// `DeviceBooter.sweepRefusal` / `mcpSweepRefusal`(どちらも見出し込みの完成文)を呼び、
// 両方とも保持者が居るときだけ見出しの重複を剥がして1本の文へ束ねる。本文はどちらも
// DeviceBooter 側の既存文言を使い回し、ここでは新しい文言を作らない。

import FTAndroid
import FTBridgeClient

enum BridgeDownRefusal {
    static func decide(
        targets: [(name: String, keys: [String])],
        force: Bool,
        runHolderPID: (String) -> Int32?,
        mcpHolderPID: (String) -> Int32?,
        selfPID: Int32
    ) -> String? {
        guard !force else { return nil }
        var describeByKey: [String: String] = [:]
        for target in targets {
            for key in target.keys where describeByKey[key] == nil {
                describeByKey[key] = target.name
            }
        }
        let runRefusal = DeviceBooter.sweepRefusal(
            keys: targets.flatMap(\.keys), selfPID: selfPID, force: force,
            holderPID: runHolderPID, describe: { describeByKey[$0] ?? $0 })
        let mcpHolders: [(device: String, pid: Int32)] = targets.compactMap { target in
            target.keys.lazy.compactMap(mcpHolderPID).first.map { (target.name, $0) }
        }
        let mcpRefusal = DeviceBooter.mcpSweepRefusal(holders: mcpHolders, force: force)
        return combine(run: runRefusal, mcp: mcpRefusal)
    }

    /// scan に載らなかった(= /status が返らなかった)ポートの扱い。
    /// **待受しているのに応答しない = 忙しい**(XCUITest はアプリを駆動している間 /status を返さず、
    /// quiescence 待ちで数十秒ブロックする)。鍵(udid)が引けないので lease も照合できず、
    /// そのまま通すと**駆動中のセッションを黙って壊す**(負荷テストで実測: MCP が
    /// 操作中のブリッジが `bridge down --port` で無言のまま止まり、そのセッションは
    /// 「no running bridge」しか返さなくなった)。**止めずに断り、`--force` を案内する**。
    ///
    /// **ただし「忙しい」と「固まった転送」を混ぜない**(docs/maintainer-notes.md §44.1 と同じ判定を
    /// この口にも通す): ブリッジが死んで iproxy だけがポートを握っている形は、connect は通るのに
    /// 即座に切れる(`.transportFailed`)。これを busy と読むと**止めることが唯一の回復手段なのに
    /// 「待て」と言い続ける**袋小路になる(実地の負荷テスト: 画面ロックで死んだ実機の
    /// トンネルが握ったポートを `bridge down --port` が延々と断った)。
    /// 待受もしていないポート(`.notBound`)は「止めるものが無い」のでそのまま通す
    static func unresponsiveButBoundRefusal(
        ports: [UInt16], force: Bool,
        probe: (UInt16) -> BridgeDiscovery.StatusProbe
    ) -> String? {
        guard !force else { return nil }
        let busy = ports.filter { probe($0) == .timedOut }
        guard !busy.isEmpty else { return nil }
        let list = busy.map(String.init).joined(separator: ", ")
        return "refusing to stop: port \(list) "
            + (busy.count == 1 ? "is" : "are")
            + " listening but did not answer /status — most likely busy driving the app"
            + " (XCUITest does not answer while it runs a request), and stopping now would break"
            + " whatever is driving it. Wait for it to go idle, or pass --force to stop it anyway."
    }

    private static func combine(run: String?, mcp: String?) -> String? {
        let heading = DeviceBooter.sweepRefusalHeading
        func body(_ text: String) -> String {
            text.hasPrefix(heading) ? String(text.dropFirst(heading.count)) : text
        }
        switch (run, mcp) {
        case let (run?, mcp?): return heading + DeviceBooter.sentenceJoined(body(run), body(mcp))
        case let (run?, nil): return run
        case let (nil, mcp?): return mcp
        case (nil, nil): return nil
        }
    }
}
