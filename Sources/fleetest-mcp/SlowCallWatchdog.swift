// 止まった呼び出しの記録(打ち切らない)。MCP のツール呼び出しが答えないまま止まった実例があり(ft_tap / ft_launch /
// ft_status が数分〜8分半。サーバの中で返らない非同期の待ちに入り、スレッドも塞がない = スタックにも出ない)、
// どこで待っていたかを外から知る手段が無かった。
// 呼び出しが `reportAfterSeconds` を超えたら、ツール名・いまの段階(`mark`)・ブリッジへ出している要求
// (`BridgeClient.inFlightRequests`)を標準エラーと `.fleetest/mcp-slow-calls.log` に書く(以後も同じ間隔で書く)。
// **打ち切らない**: ランナーの初回のビルドのように正当に数分かかる段があり、打ち切る上限は止まる段が分かってから決める

import Foundation
import FTCore
import FTBridgeClient

struct SlowCallWatchdog: Sendable {
    /// 記録し始めるまでの秒。**根拠**: 正常に終わった呼び出しの最長は 25 秒(ft_batch。Claude Code の MCP のログに
    /// 残る全呼び出しの実測)、止まった呼び出しは 2 分超。最長の2倍強。**尽きたとき**: 記録を書くだけ(呼び出しは続く)
    static let reportAfterSeconds: Double = 60

    private struct Entry: Sendable {
        let tool: String
        let started: Date
        var phase: String
        var phaseSince: Date
        /// 段階ごとの所要の積算(初出の順)。`segmentStart` は積算の区切り = 最後に段階が変わった時刻
        /// (`phaseSince` は入れ子を抜けると外側の開始へ戻るので、積算には使えない)
        var spent: [(phase: String, seconds: Double)] = []
        var segmentStart: Date

        mutating func closeSegment(at now: Date) {
            let seconds = now.timeIntervalSince(segmentStart)
            if let index = spent.firstIndex(where: { $0.phase == phase }) {
                spent[index].seconds += seconds
            } else {
                spent.append((phase, seconds))
            }
            segmentStart = now
        }
    }
    private static let entries = LockedValue<[Int: Entry]>([:])

    let callID: Int
    private let reporter: Task<Void, Never>

    static func start(callID: Int, tool: String) -> SlowCallWatchdog {
        let now = Date()
        entries.withLock { $0[callID] = Entry(tool: tool, started: now, phase: "starting", phaseSince: now,
                                                     segmentStart: now) }
        let reporter = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(reportAfterSeconds * 1_000_000_000))
                guard !Task.isCancelled, let line = report(callID: callID, now: Date()) else { return }
                write(line)
            }
        }
        return SlowCallWatchdog(callID: callID, reporter: reporter)
    }

    func finish() {
        reporter.cancel()
        _ = Self.entries.withLock { $0.removeValue(forKey: callID) }
    }

    /// いまの呼び出し(`MCPServer.currentCallID`)の段階を書き換え、前の段階を返す(`restore` に渡す)。
    /// 呼び出しの外(番号 0)では何もしない
    @discardableResult
    static func mark(_ phase: String) -> (phase: String, since: Date)? {
        let callID = MCPServer.currentCallID
        guard callID != 0 else { return nil }
        let now = Date()
        return entries.withLock { entries in
            guard var entry = entries[callID] else { return nil }
            let previous = (entry.phase, entry.phaseSince)
            entry.closeSegment(at: now)
            entry.phase = phase
            entry.phaseSince = now
            entries[callID] = entry
            return previous
        }
    }

    /// `mark` の前の段階へ戻す(入れ子の段階を抜けたとき。外側の段階の経過秒は外側の開始から数える)
    static func restore(_ previous: (phase: String, since: Date)?) {
        let callID = MCPServer.currentCallID
        guard callID != 0, let previous else { return }
        entries.withLock { entries in
            guard var entry = entries[callID] else { return }
            entry.closeSegment(at: Date())
            entry.phase = previous.phase
            entry.phaseSince = previous.since
            entries[callID] = entry
        }
    }

    /// `body` の間だけ段階を `phase` にする
    static func marking<T>(_ phase: String, _ body: () async throws -> T) async rethrows -> T {
        let previous = mark(phase)
        defer { restore(previous) }
        return try await body()
    }

    /// いまの呼び出しの段階ごとの所要(秒・初出の順。0.1 秒未満の段階は落とす)。呼び出しの外では空
    static func breakdown(now: Date = Date()) -> [(phase: String, seconds: Double)] {
        let callID = MCPServer.currentCallID
        guard callID != 0, var entry = entries.withLock({ $0[callID] }) else { return [] }
        entry.closeSegment(at: now)
        return entry.spent.filter { $0.seconds >= 0.1 }
    }

    /// 記録の1行(呼び出しが既に終わっていれば nil)
    static func report(callID: Int, now: Date) -> String? {
        guard let entry = entries.withLock({ $0[callID] }) else { return nil }
        let inFlight = BridgeClient.inFlightRequests(now: now)
        return "slow call: \(entry.tool) (call #\(callID)) still running after \(Int(now.timeIntervalSince(entry.started)))s"
            + " — phase: \(entry.phase) (for \(Int(now.timeIntervalSince(entry.phaseSince)))s)"
            + "; bridge requests in flight: " + (inFlight.isEmpty ? "none" : inFlight.joined(separator: ", "))
    }

    private static func write(_ line: String) {
        MCPServer.logStderr(line)
        append(line, to: ".fleetest/mcp-slow-calls.log")
    }

    /// 要求の受信・応答の送信を1行ずつ残す(`.fleetest/mcp-rpc.log`)。応答の返らない呼び出しが、サーバに届かなかったのか・
    /// 応答が書かれたのにクライアントが受け取らなかったのかを分ける(実測: ft_launch が返らず、ランナーにも端末の台帳にも
    /// 跡が無かった。サーバは stdin 待ちで止まっていた)。**stdio のメインループからだけ呼ぶ**(テストが本物の台帳へ書かない)。
    /// 上限 `rpcTraceMaxBytes` を超えたら `.prev` へ回す
    static func traceRPC(_ line: String) {
        append(line, to: ".fleetest/mcp-rpc.log", rotateAbove: rpcTraceMaxBytes)
    }
    /// 1行は約 100 バイト・1呼び出し2行 = 約 1 万呼び出しぶん。**尽きたとき**: それまでの分を `.prev` に1世代だけ残して書き続ける
    static let rpcTraceMaxBytes = 2_000_000

    private static func append(_ line: String, to relativePath: String, rotateAbove limit: Int? = nil) {
        guard let root = try? RepoRoot.find() else { return }
        let url = root.appendingPathComponent(relativePath)
        if let limit, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > limit {
            let prev = url.appendingPathExtension("prev")
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: url, to: prev)
        }
        // ミリ秒まで(要求2本が 0.2 秒差で届いた形を順序で読む)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamped = formatter.string(from: Date()) + " pid \(ProcessInfo.processInfo.processIdentifier) " + line + "\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(stamped.utf8))
    }
}
