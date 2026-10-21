import Foundation
import XCTest

/// 契約: `BridgeDiscovery.scan` は**答えなかったポートを黙って捨てる**。忙しい XCUITest ランナーは待受したまま
/// 2 秒以上答えないので、「走査に載らない」を「居ない」と読んで判断(採用・起動・停止・「無い」の断定)をすると
/// 別の端末を操作する・生きたランナーを殺す。判断に使う呼び手は `scanDetailed`(`silent` を返す)を使い、
/// `scan` の呼び手は**答えなかったことをどう扱うか**をこの表に理由つきで書く。
/// 呼び手が増える・減ると落ちる(ソース走査。コメント行は数えない)。
final class BridgeScanCallerAuditTests: XCTestCase {

    private static let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// 呼び手の数 + 答えないポートの扱い。表の更新は「答えない = 居ない」と畳んでいないことを確かめてから
    static let scanCallers: [String: (count: Int, handling: String)] = [
        "fleetest-mcp/DeviceInventory.swift": (1, "表示だけ(判断に使わない)"),
        "fleetest-mcp/MCPServer+ConnectionLoss.swift": (2, "診断の補助。待受の有無は mayBeListening で別に見る"),
        "fleetest-mcp/MCPServer+Driver.swift": (1, "udid で濾すだけ。無いときは portForIOS が mayBeListening / 診断で補う"),
        "fleetest/BridgeCommand.swift": (2, "bridge down: 載らなかったポートは probeStatus と unresponsiveButBoundRefusal で別に門を掛ける"),
        "fleetest/ApiLiveCommand.swift": (2, "udid の一致を探して乗り換えるだけ。載らなければ busyRunnerPort(ps + 接続試行)と自動起動の門が見る"),
    ]

    /// 答えなかったポートも受け取る呼び手
    static let scanDetailedCallers: [String: (count: Int, handling: String)] = [
        "FTBridgeClient/BridgeTargetResolution.swift": (1, "decide に silent を渡し、1本採用を「唯一」と言わない"),
        "fleetest/BridgeCommand.swift": (1, "bridge status: 待受だけのポートも行にし、「無い」は両方空のときだけ"),
    ]

    private func counts(pattern: String) throws -> [String: Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        var result: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(at: Self.sourcesDir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var n = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                n += regex.numberOfMatches(in: String(line), range: range)
            }
            if n > 0 {
                result[String(url.path.dropFirst(Self.sourcesDir.path.count + 1))] = n
            }
        }
        return result
    }

    func testScanCallersAreExactlyTheAuditedSet() throws {
        let found = try counts(pattern: #"\.scan\(excluding"#)
        XCTAssertEqual(found, Self.scanCallers.mapValues(\.count),
                       "scan の呼び手が変わった。答えなかったポート(busy)をどう扱うかを表に書くか、scanDetailed を使うこと")
    }

    func testScanDetailedCallersAreExactlyTheAuditedSet() throws {
        let found = try counts(pattern: #"\.scanDetailed\(excluding"#)
        XCTAssertEqual(found, Self.scanDetailedCallers.mapValues(\.count),
                       "scanDetailed の呼び手が変わった。silent の扱いを表に書くこと")
    }

    /// 走査が Sources に届いていること(空の一致で等号が成り立たない)
    func testScanReachesSources() throws {
        XCTAssertFalse(try counts(pattern: #"\.scan\(excluding"#).isEmpty)
    }

    /// 宛先省略の解決が、走査の silent を判定へ渡していること(渡さない `silent: []` に戻すと「唯一」と言って採る)
    func testIosPortFeedsSilentIntoTheDecision() throws {
        let url = Self.sourcesDir.appendingPathComponent("FTBridgeClient/BridgeTargetResolution.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("silent: scanned.silent"), "decide へ silent を渡すこと")
    }
}
