// `remote machines list --json` と `api remote-machines` の JSON は同じ 1 形(§18 の残件: 2 形あった)。
// 出力は ConsoleOut 経由なので、口が 1 つであることをソース走査で固定する

import XCTest

final class RemoteMachinesJSONShapeTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testMachinesListJSONGoesThroughTheAPIEmitter() throws {
        let remote = try source("Sources/fleetest/RemoteCommands.swift")
        XCTAssertTrue(remote.contains("ApiRemoteHostsCommand.emit(entries)"),
                      "remote machines list --json が api remote-machines と別の形を持っている")
        XCTAssertFalse(remote.contains("MachinesListJSON"), "旧形 {\"machines\":[…]} が残っている")
        let api = try source("Sources/fleetest/ApiRemoteHostsCommand.swift")
        XCTAssertTrue(api.contains("static func emit(_ entries: [RemoteHostEntry])"),
                      "共通の口 ApiRemoteHostsCommand.emit が無い")
    }
}
