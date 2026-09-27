// `runInherited`(rsync・`ssh … mkdir -p`)の stdout の行き先。apiRun の親の stdout は NDJSON
// 専用の契約なので、混入を防げない経路(ssh 越しのシェル初期化ファイルの出力等)は stderr へ
// 逃がす必要がある。実プロセスは起動せず、行き先を決める純粋関数だけを固定する。

import XCTest
@testable import fleetest

final class RunInheritedStdoutRoutingTests: XCTestCase {
    func testApiRunRedirectsToStderr() {
        XCTAssertTrue(runInheritedStdoutGoesToStderr(mode: .apiRun))
    }

    func testCliRunKeepsStdout() {
        XCTAssertFalse(runInheritedStdoutGoesToStderr(mode: .cliRun))
    }
}
