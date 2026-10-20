import XCTest
@testable import FTCore

/// 待ち受けの fd を閉じるのは受付のスレッドだけ(AcceptLoop の宣言)。別のスレッドが閉じると番号が再利用され、
/// 受付のスレッドの次の accept が無関係の待ち受けへの接続を奪う(BridgeRelay を並列で立て直すと 1600 回中 353 回)
final class AcceptLoopTests: XCTestCase {
    private static func listen(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private static func port(of fd: Int32) -> UInt16 {
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: actual.sin_port)
    }

    /// stop() から戻った時点で待ち受けは閉じている = 同じ番号へすぐ立て直せる(シナリオごとに同じ番号で立て直す前提)。
    /// 立て直した側の接続は立て直した側の受付に届く
    func testStopReturnsAfterTheListenerIsClosedSoTheSamePortCanBeReboundAtOnce() throws {
        let first = try Self.listen(port: 0)
        let port = Self.port(of: first)
        let loop = try AcceptLoop(listener: first, name: "test-first") { client in close(client); return true }
        loop.stop()
        let accepted = expectation(description: "立て直した待ち受けが受ける")
        let second = try Self.listen(port: port)
        let rebuilt = try AcceptLoop(listener: second, name: "test-second") { client in
            close(client)
            accepted.fulfill()
            return false
        }
        defer { rebuilt.stop() }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        wait(for: [accepted], timeout: 10)
        loop.stop()  // 2回目も返る
    }

    /// 生の accept を書いてよいのは、待ち受けを同じ関数(= 同じスレッド)の defer で閉じる型だけ。
    /// 待ち受けを持つ型を足すときは AcceptLoop を通すか、ここへ理由を書く
    private static let rawAcceptAllowed: [String: String] = [
        "AcceptLoop.swift": "受付のスレッドそのもの",
        "VisionHelperServer.swift": "待ち受けを accept のループと同じ関数の defer で閉じる",
        "FramedUnixSocket.swift": "待ち受けを accept のループと同じ関数の defer で閉じる",
    ]

    func testRawAcceptLivesOnlyWhereTheAcceptingThreadClosesTheListener() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // 関数の宣言(`func accept(`)・メソッド呼び出し(`.accept(`)は数えない = システムコールの accept だけ
        let call = try NSRegularExpression(pattern: #"(?<![.\w])(?<!func )accept\("#)
        var files: Set<String> = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if call.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                files.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(files, Set(Self.rawAcceptAllowed.keys),
                       "生の accept を書くファイルが増えた/減った —— 待ち受けは AcceptLoop を通すか、理由を表へ書く")
    }
}
