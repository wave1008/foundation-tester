// 要求の流れを fd 0 から引き剥がす(MCPServer.detachRequestStream)。子プロセスが fd 0 を受け継いで次の要求の行を
// 読んで消していた(ft_launch が永久に返らなかった)。剥がした後の fd 0 は何も読めず、要求は剥がした流れから全部読めること

import XCTest
@testable import fleetest_mcp

final class MCPRequestStreamDetachTests: XCTestCase {

    func testTheOriginalFDNoLongerYieldsRequestsAndTheDetachedStreamYieldsAll() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let message = "{\"id\":4}\n{\"id\":5}\n"
        _ = message.withCString { write(fds[1], $0, strlen($0)) }
        close(fds[1])

        let stream = try XCTUnwrap(MCPServer.detachRequestStream(fd: fds[0]))
        defer { fclose(stream); close(fds[0]) }
        // 子が受け継ぐ fd(元の番号)は /dev/null = 読んでも何も来ない
        var byte: UInt8 = 0
        XCTAssertEqual(read(fds[0], &byte, 1), 0)
        XCTAssertEqual(MCPServer.readRequestLine(stream), "{\"id\":4}")
        XCTAssertEqual(MCPServer.readRequestLine(stream), "{\"id\":5}")
        XCTAssertNil(MCPServer.readRequestLine(stream))
    }
}
