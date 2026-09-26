// SimulatorStorageProbe の純粋パーサ(du -sk の出力解析)。du の実行そのものは対象外(ホスト依存)。

import XCTest
@testable import FTBridgeClient

final class SimulatorStorageProbeTests: XCTestCase {

    func testParsesTabSeparatedDuOutput() {
        XCTAssertEqual(SimulatorStorageProbe.parse(duOutput: "1234567\t/path/to/data\n"), 1_234_567)
    }

    func testParsesSpaceSeparatedDuOutput() {
        XCTAssertEqual(SimulatorStorageProbe.parse(duOutput: "42 /path/to/data"), 42)
    }

    func testUnparsableOutputReturnsNil() {
        XCTAssertNil(SimulatorStorageProbe.parse(duOutput: ""))
        XCTAssertNil(SimulatorStorageProbe.parse(duOutput: "du: cannot access"))
    }

    /// 間隔の既定値をリテラルで固定する(docs/results-json.md「間隔: … iOS Simulator 10 分」)
    func testDefaultProbeIntervalIsTenMinutes() {
        XCTAssertEqual(SimulatorStorageProbe.probeIntervalSeconds, 1800)
    }
}
