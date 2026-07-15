// BridgeClient の per-endpoint タイムアウト(interaction/session)が効くことを、応答しない
// ローカル TCP リスナ相手に短縮予算を注入して検証する。実デバイス不要・数秒で完了する。
// 検証対象: tap 系は interactionTimeout、status/launch 系は sessionTimeout を使う契約。

import XCTest
@testable import FTBridgeClient
import FTCore

/// 接続は受理するが応答を一切返さないループバック TCP リスナ。接続後アイドルのままにするため、
/// クライアントは URLRequest.timeoutInterval(注入した予算)でタイムアウトする。
private final class UnresponsiveTCPListener {
    private var serverFD: Int32 = -1
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS にエフェメラルポートを採番させる
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw Failure.bind(errno) }
        guard listen(fd, 8) == 0 else { close(fd); throw Failure.listen(errno) }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: assigned.sin_port)
        self.serverFD = fd

        // accept したクライアント接続は閉じない(閉じると接続断エラーになりタイムアウトを検証できない)。
        // テストは短命なので受理した fd はそのまま保持(意図的リーク)。
        Thread.detachNewThread { [fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }  // serverFD の close で accept が失敗し脱出
            }
        }
    }

    func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    deinit { stop() }

    enum Failure: Error { case socket(Int32), bind(Int32), listen(Int32) }
}

final class BridgeClientTimeoutTests: XCTestCase {

    func testInteractionEndpointUsesInteractionBudget() async throws {
        let listener = try UnresponsiveTCPListener()
        defer { listener.stop() }
        // interaction=0.5s / session=5s。tap は interaction 予算で切れるはず
        let client = BridgeClient(port: listener.port, timeoutSeconds: 30,
                                  interactionTimeout: 0.5, sessionTimeout: 5)
        let start = Date()
        do {
            try await client.tap(x: 1, y: 1)
            XCTFail("応答しないリスナ相手にタイムアウトするはず")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            guard case DriverError.bridgeUnreachable = error else {
                return XCTFail("タイムアウトは bridgeUnreachable のはず: \(error)")
            }
            XCTAssertLessThan(elapsed, 2.5, "interaction 予算(0.5s)で切れるべき。実測 \(elapsed)s")
        }
    }

    func testSessionEndpointUsesSessionBudget() async throws {
        let listener = try UnresponsiveTCPListener()
        defer { listener.stop() }
        // interaction=5s / session=0.5s。status は session 予算で切れるはず(interaction では切れない)
        let client = BridgeClient(port: listener.port, timeoutSeconds: 30,
                                  interactionTimeout: 5, sessionTimeout: 0.5)
        let start = Date()
        do {
            _ = try await client.status()
            XCTFail("応答しないリスナ相手にタイムアウトするはず")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            guard case DriverError.bridgeUnreachable = error else {
                return XCTFail("タイムアウトは bridgeUnreachable のはず: \(error)")
            }
            XCTAssertLessThan(elapsed, 2.5, "session 予算(0.5s)で切れるべき。実測 \(elapsed)s")
        }
    }
}
