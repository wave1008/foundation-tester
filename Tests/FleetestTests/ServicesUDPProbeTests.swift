import Darwin
import FTServices
import Foundation
import XCTest
@testable import fleetest

/// 送受信の部品を 127.0.0.1 の本物のソケットで固定する(エコーはテストの中)。判定の中身は FTServices.UDPReachability
final class ServicesUDPProbeTests: XCTestCase {

    /// 受けた datagram / 行をそのまま返すエコー(UDP と TCP)
    private final class LoopbackEcho: @unchecked Sendable {
        let udpPort: UInt16
        let tcpPort: UInt16
        private let udp: Int32
        private let tcp: Int32

        init() throws {
            func bound(_ type: Int32) throws -> (Int32, UInt16) {
                let fd = socket(AF_INET, type, 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                address.sin_port = 0
                let ok = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard fd >= 0, ok == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
                var actual = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &actual) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                return (fd, UInt16(bigEndian: actual.sin_port))
            }
            (udp, udpPort) = try bound(SOCK_DGRAM)
            (tcp, tcpPort) = try bound(SOCK_STREAM)
            listen(tcp, 4)
            let udpFD = udp
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var peer = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                while true {
                    let count = withUnsafeMutablePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udpFD, &buffer, buffer.count, 0, $0, &length) }
                    }
                    guard count > 0 else { return }
                    _ = withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udpFD, buffer, count, 0, $0, length) }
                    }
                }
            }
            let tcpFD = tcp
            Thread.detachNewThread {
                while true {
                    let client = accept(tcpFD, nil, nil)
                    guard client >= 0 else { return }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(client, &buffer, buffer.count)
                    if count > 0 { _ = write(client, buffer, count) }
                    close(client)
                }
            }
        }

        func stop() { close(udp); close(tcp) }
    }

    func testEchoIsReachedOnTheFirstProbeAndTCPToo() throws {
        let echo = try LoopbackEcho()
        defer { echo.stop() }
        XCTAssertEqual(ServicesUDPProbe.probeUDP(hostPort: Int(echo.udpPort)), .reached(attempt: 1))
        XCTAssertTrue(ServicesUDPProbe.probeTCP(hostPort: Int(echo.tcpPort)))
    }

    /// 誰も待ち受けないポートには届かない(試行の回数だけ待つ = 2 回 × 0.2 s)
    func testNobodyListeningIsUnreachedAfterTheGivenAttempts() throws {
        let probe = try LoopbackEcho()
        let udpPort = Int(probe.udpPort)
        let tcpPort = Int(probe.tcpPort)
        probe.stop()  // 番号だけ使う(閉じた直後なので誰も待ち受けない)
        let started = Date()
        XCTAssertEqual(ServicesUDPProbe.probeUDP(hostPort: udpPort, attempts: 2, timeoutSeconds: 0.2), .unreached(attempts: 2))
        XCTAssertFalse(ServicesUDPProbe.probeTCP(hostPort: tcpPort, timeoutSeconds: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "試行の上限を超えて待っている")
    }
}
