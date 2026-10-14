import Darwin
import Foundation
import XCTest
@testable import fleetest

/// 転送器の配管を 127.0.0.1 の本物のソケットで固定する(ゲートウェイのアドレスは Apple のコンテナが付いている間しか無い)
final class ServicesGatewayForwarderTests: XCTestCase {

    private final class LineEcho: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        init() throws {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, Darwin.listen(listener, 4) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
            }
            port = UInt16(bigEndian: actual.sin_port)
            fd = listener
            Thread.detachNewThread {
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(client, &buffer, buffer.count)
                    if count > 0 {
                        let reply = Array("echo:".utf8) + buffer[..<count]
                        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                    }
                    close(client)
                }
            }
        }
        func stop() { close(fd) }
    }

    private func exchange(port: UInt16, _ text: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return "connect failed" }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = text.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : "no reply"
    }

    func testBytesFlowBothWaysThroughTheForwarder() throws {
        let echo = try LineEcho()
        defer { echo.stop() }
        let listenPort = try ServicesFacts.freeCheckPorts(reserved: []).tcp
        let forwarder = try ServicesGatewayForwarder(listenAddress: "127.0.0.1", listenPort: UInt16(listenPort), targetPort: echo.port)
        defer { forwarder.stop() }
        XCTAssertEqual(exchange(port: UInt16(listenPort), "ping\n"), "echo:ping\n")
        XCTAssertEqual(exchange(port: UInt16(listenPort), "second\n"), "echo:second\n", "2 本目の接続も受ける")
    }

    /// リクエストの後に書き側を閉じるクライアント(half-close)でも応答が届く = 片方向の EOF で両端を切らない
    func testHalfClosedClientStillReceivesTheReply() throws {
        let echo = try LineEcho()
        defer { echo.stop() }
        let listenPort = try ServicesFacts.freeCheckPorts(reserved: []).tcp
        let forwarder = try ServicesGatewayForwarder(listenAddress: "127.0.0.1", listenPort: UInt16(listenPort), targetPort: echo.port)
        defer { forwarder.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(listenPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = "late\n".withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)  // 書き側を閉じてから読む
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertEqual(count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : "no reply", "echo:late\n")
    }

    func testStoppedForwarderRefusesNewConnections() throws {
        let echo = try LineEcho()
        defer { echo.stop() }
        let listenPort = try ServicesFacts.freeCheckPorts(reserved: []).tcp
        let forwarder = try ServicesGatewayForwarder(listenAddress: "127.0.0.1", listenPort: UInt16(listenPort), targetPort: echo.port)
        forwarder.stop()
        XCTAssertEqual(exchange(port: UInt16(listenPort), "ping\n"), "connect failed")
    }
}
