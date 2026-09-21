// 機械グローバルな `~/.fleetest` の唯一の定義元(Sources/FTCore/MachineStateDirectory.swift)。
// ここを通る台帳(runs / fm-usage / dispatch.lock / dispatch.queue)は「同じ Mac なら同じ1本」が
// 成立条件なので、綴りは完全一致で固定する。

import Foundation
import XCTest
import FTCore

final class MachineStateDirectoryTests: XCTestCase {

    func testPathIsHomePlusDotFleetest() {
        XCTAssertEqual(MachineStateDirectory.path(home: "/Users/tester"), "/Users/tester/.fleetest")
    }

    /// 末尾のスラッシュは畳む —— 畳まないと `//.fleetest` が別の綴りになり、
    /// 同じ機械のロックが文字列としては2本に見える
    func testTrailingSlashesAreFolded() {
        XCTAssertEqual(MachineStateDirectory.path(home: "/Users/tester/"), "/Users/tester/.fleetest")
        XCTAssertEqual(MachineStateDirectory.path(home: "/Users/tester///"), "/Users/tester/.fleetest")
        XCTAssertEqual(MachineStateDirectory.path(home: "/"), "/.fleetest")
    }

    /// `remote status` の1往復だけは `$HOME` を未解決のまま埋める(リモートシェルが展開する)。
    /// ここで畳んだり展開したりしないこと
    func testUnresolvedHomeIsPassedThrough() {
        XCTAssertEqual(MachineStateDirectory.path(home: "$HOME"), "$HOME/.fleetest")
    }

    func testURLFormMatchesThePathForm() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(MachineStateDirectory.url(home: home).path, MachineStateDirectory.path(home: home.path))
    }
}
