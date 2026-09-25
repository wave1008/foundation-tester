// BridgeDiscovery.connectProbe: isBound の 300ms 判定を「refused(誰も居ないと確定)」と
// 「connected(誰か居る)」に割る境界。破壊的な掃除(BridgeProvisioner.sweepStuckStartingRunners)が
// timeout/unknown を「居ない」の根拠にしないための材料になる。

import XCTest
@testable import FTBridgeClient

final class ConnectProbeTests: XCTestCase {

    func testRefusedWhenNobodyIsListening() throws {
        let port = try TestPorts.withNoListener()
        XCTAssertEqual(BridgeDiscovery.connectProbe(port: port, repoRoot: nil), .refused)
    }

    func testConnectedWhenSomeoneIsListening() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("socket を開けない") }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS にエフェメラルポートを採番させる
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw XCTSkip("listen できない") }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: assigned.sin_port)
        // accept は撃たない —— connect() の成立は listen backlog への到達だけで決まり、
        // アプリが accept するかどうかは無関係(busy な XCUITest と同じ状況を模す)
        XCTAssertEqual(BridgeDiscovery.connectProbe(port: port, repoRoot: nil), .connected)
        // **busy(誰か居る)は refused ではない** —— sweepStuckStartingRunners は `.refused` に
        // 一致したときだけ進むので、この形は timeout と同じく「居ない」扱いされないことの根拠になる
        XCTAssertNotEqual(BridgeDiscovery.connectProbe(port: port, repoRoot: nil), .refused)
    }

    /// isBound は connectProbe の薄いラッパーであり、3値のうち connected だけを true に畳む
    /// (既存の全呼び手の契約を変えないこと)
    func testIsBoundIsTrueOnlyForConnected() throws {
        let refusedPort = try TestPorts.withNoListener()
        XCTAssertFalse(BridgeDiscovery.isBound(port: refusedPort, repoRoot: nil))
    }
}
