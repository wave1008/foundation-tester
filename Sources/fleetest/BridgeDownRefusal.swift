// `fleetest bridge down --all` の門(純粋関数。I/O は呼び出し側が注入する holderPID で持つ)。
// --port(単体)は `DeviceBooter.deviceInUseRefusal` をそのまま使えば足りるが、--all は
// 複数ポートをまとめて「1台でも保持者が居れば掃討ごと断る」形にする必要があるため、
// `DeviceBooter.sweepRefusal` / `mcpSweepRefusal`(どちらも見出し込みの完成文)を呼び、
// 両方とも保持者が居るときだけ見出しの重複を剥がして1本の文へ束ねる。本文はどちらも
// DeviceBooter 側の既存文言を使い回し、ここでは新しい文言を作らない。

import FTAndroid

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
