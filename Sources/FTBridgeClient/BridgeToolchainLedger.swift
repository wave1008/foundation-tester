// 稼働中ブリッジが「どの Xcode/SDK で起動されたか」をポート台帳の隣
// (.fleetest/bridge-<port>.toolchain)に控える。
//
// **成果物側の指紋(<DerivedData>/.toolchain・InAppBridge/build/.toolchain)と比べてはいけない** ——
// 成果物は BridgeLauncher.runnerRebuildReason が後から独立に作り直しうるので、「ディスクは新しい
// Xcode で建て直し済みだが、動いているプロセスは旧 Xcode のまま」という食い違いを検出できない。
// ここは起動した**時点**の値を控え、BridgeProvisioner の .reuse/.adopt 経路がそれと比べる。

import Foundation
import FTCore

public enum BridgeToolchainLedger {

    public static func url(stateDir: URL, port: UInt16) -> URL {
        stateDir.appendingPathComponent("bridge-\(port).toolchain")
    }

    /// ブリッジが ready になった直後に呼ぶ。失敗は握りつぶす(控えが無ければ次回
    /// matchesCurrent が false = 作り直すだけで、壊れはしない。ToolchainFingerprint.store と同じ規律)
    public static func record(stateDir: URL, port: UInt16,
                              toolchain: String? = ToolchainFingerprint.current()) {
        guard let toolchain else { return }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? toolchain.write(to: url(stateDir: stateDir, port: port), atomically: true, encoding: .utf8)
    }

    /// **判定できない場合(未保存・読めない・現在値が取れない)は false = 再利用せず作り直す側へ倒す**
    /// (ToolchainFingerprint.matches と同じ規律)
    public static func matchesCurrent(stateDir: URL, port: UInt16,
                                      current: String? = ToolchainFingerprint.current()) -> Bool {
        guard let current,
              let stored = try? String(contentsOf: url(stateDir: stateDir, port: port), encoding: .utf8)
        else { return false }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == current
    }

    /// 生きているブリッジを再利用してよいか。**リースのある台には触らない**
    /// (supplySlownessAction と同じ規律 —— 他プロセスの run・MCP が使用中のブリッジを
    /// 版差だけで殺すとその run を壊す)。**止められないときも黙って使わない** ——
    /// 版の違うブリッジを駆動している事実は変わらないので、呼び手は1行言う
    public enum ReuseDecision: Equatable, Sendable {
        case reuse
        case warnAndReuse
        case restart
    }

    public static func decide(toolchainMatches: Bool, hasForeignLease: Bool) -> ReuseDecision {
        if toolchainMatches { return .reuse }
        return hasForeignLease ? .warnAndReuse : .restart
    }

    public static func remove(stateDir: URL, port: UInt16) {
        try? FileManager.default.removeItem(at: url(stateDir: stateDir, port: port))
    }
}
