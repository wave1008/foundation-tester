// HybridFallbackIdentity.drifted の I/O(/status を撃って判定へ渡す)配線を、実ブリッジ無しで
// 固定する。判定そのもの(BridgeIdentityCheck.hybridFallbackDrift)は
// Tests/FTCoreTests/BridgeIdentityCheckTests.swift が純粋関数として確かめてあるので、
// ここで見るのは「その判定へ正しい status を渡せているか」と「不明を変わったに倒さないか」。
//
// 呼び手は MCP(fleetest-mcp)とライブ操作(api live serve)の2つ。どちらもこの関数を
// そのまま呼ぶので、ここで固定すれば両方が守られる。

import XCTest
@testable import FTBridgeClient
import FTCore

/// `/status` にだけ応答する最小 HTTP スタブ(Tests/FTBridgeClientTests/AppAttachDriverAttachTests.swift
/// の RecordingStubServer と同じ作法。返す body を注入できるようにした版)
private final class StatusStubServer {
    private var serverFD: Int32 = -1
    let port: UInt16

    init(status: StatusResponse) throws {
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

        let body = (try? String(data: JSONEncoder().encode(status), encoding: .utf8)) ?? "{}"
        Thread.detachNewThread { [fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }  // serverFD の close で accept が失敗し脱出
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(c, &buffer, buffer.count)  // リクエストの中身は読み捨てる(/status しか撃たない)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { if serverFD >= 0 { close(serverFD); serverFD = -1 } }
    deinit { stop() }

    enum Failure: Error { case socket(Int32), bind(Int32), listen(Int32) }
}

final class HybridFallbackIdentityTests: XCTestCase {

    func testMatchingUDIDIsNotDrifted() async throws {
        let stub = try StatusStubServer(status: StatusResponse(
            ready: true, device: "iPhone 17 Pro-02", osVersion: "-", sessionBundleID: nil,
            engine: "xcuitest", udid: "SIM-1"))
        defer { stub.stop() }

        let drifted = await HybridFallbackIdentity.drifted(
            port: stub.port, expectedUDID: "SIM-1", repoRoot: nil)

        XCTAssertEqual(drifted, .none)
    }

    /// **本命**: fallback ポートが実際に別デバイスの XCUITest ブリッジへ移った形
    func testDifferentUDIDIsDrifted() async throws {
        let stub = try StatusStubServer(status: StatusResponse(
            ready: true, device: "iPhone 17 Pro-05", osVersion: "-", sessionBundleID: nil,
            engine: "xcuitest", udid: "SIM-2"))
        defer { stub.stop() }

        let drifted = await HybridFallbackIdentity.drifted(
            port: stub.port, expectedUDID: "SIM-1", repoRoot: nil)

        XCTAssertEqual(drifted, .differentDevice, "fallback ポートが別デバイスの udid を名乗っているのに見逃した")
    }

    /// **maintainer-notes §51.2 の実測**: 建て直しで fallback ポートが in-app ブリッジに化けた。
    /// udid を申告しないのは実機の xcuitest だけなので、これは差し替わり(differentDevice)
    func testInAppEngineOnTheExpectedXCUITestPortIsDrifted() async throws {
        let stub = try StatusStubServer(status: StatusResponse(
            ready: true, device: "iPhone 17 Pro-05", osVersion: "-", sessionBundleID: "com.example.other",
            engine: "inapp", udid: nil))
        defer { stub.stop() }

        let drifted = await HybridFallbackIdentity.drifted(
            port: stub.port, expectedUDID: "SIM-1", repoRoot: nil)

        XCTAssertEqual(drifted, .differentDevice)
    }

    /// 同じ udid のまま engine だけ入れ替わった形は sameDeviceEngineChanged
    func testSameUDIDDifferentEngineIsSameDeviceEngineChanged() async throws {
        let stub = try StatusStubServer(status: StatusResponse(
            ready: true, device: "iPhone 17 Pro-02", osVersion: "-", sessionBundleID: "com.example.app",
            engine: "inapp", udid: "SIM-1"))
        defer { stub.stop() }

        let drifted = await HybridFallbackIdentity.drifted(
            port: stub.port, expectedUDID: "SIM-1", repoRoot: nil)

        XCTAssertEqual(drifted, .sameDeviceEngineChanged)
    }

    /// ライブ操作が主(in-app)側を確かめるときの形: `expectedEngine: "inapp"` を渡す
    func testExpectedEngineChecksTheInAppSideWhenPassed() async throws {
        let stub = try StatusStubServer(status: StatusResponse(
            ready: true, device: "iPhone 17 Pro-02", osVersion: "-", sessionBundleID: "com.example.app",
            engine: "inapp", udid: "SIM-1"))
        defer { stub.stop() }

        let drifted = await HybridFallbackIdentity.drifted(
            port: stub.port, expectedUDID: "SIM-1", expectedEngine: "inapp", repoRoot: nil)

        XCTAssertEqual(drifted, .none, "in-app を期待し in-app が答えたのに drifted と判定した")
    }

    /// **不明(接続すら失敗)は「変わった」に倒さない** —— busy/不在と区別できないので、
    /// 読めないだけでキャッシュ/合成済みドライバを毎回作り直すと健全な呼び出しが遅くなり続ける
    func testUnreachablePortIsNotDrifted() async {
        // tcpmux(ポート1)は通常誰も listen していない。connect が即座に拒否されるので短時間で終わる
        let drifted = await HybridFallbackIdentity.drifted(
            port: 1, expectedUDID: "SIM-1", repoRoot: nil, timeoutSeconds: 1)

        XCTAssertEqual(drifted, .none, "unknown(接続失敗)を「変わった」と判定した")
    }
}
