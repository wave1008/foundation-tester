// SupplyLogRelay の規則: runStarted 前は貯める / start で届いた順に流す / 以後は即時。
// 貯める理由は「拡張のレーン状態が NDJSON の runStarted で clear される」ことなので、
// **順序と1行も落とさないこと**が守りたい性質。

import XCTest
@testable import fleetest
import FTTestSupport

final class SupplyLogRelayTests: XCTestCase {

    func testHoldsLinesUntilStartThenFlushesInOrder() {
        let relay = SupplyLogRelay()
        let written = LockedBox([String]())
        let write: (String) -> Void = { line in written.mutate { $0.append(line) } }

        relay.emit("a", write: write)
        relay.emit("b", write: write)
        XCTAssertTrue(written.value.isEmpty, "runStarted 前に流すと拡張の clear で消える")

        relay.start(write: write)
        XCTAssertEqual(written.value, ["a", "b"])
    }

    func testEmitsImmediatelyAfterStart() {
        let relay = SupplyLogRelay()
        let written = LockedBox([String]())
        let write: (String) -> Void = { line in written.mutate { $0.append(line) } }

        relay.start(write: write)
        relay.emit("a", write: write)
        relay.emit("b", write: write)
        XCTAssertEqual(written.value, ["a", "b"], "start 後は貯めずに即時中継する")
    }

    /// 供給は Task で並行に走るので、貯め込みと flush が競合しても行を落とさない
    func testConcurrentEmitsAreAllDelivered() {
        let relay = SupplyLogRelay()
        let written = LockedBox([String]())
        let write: (String) -> Void = { line in written.mutate { $0.append(line) } }

        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { index in
            relay.emit("line-\(index)", write: write)
        }
        relay.start(write: write)
        XCTAssertEqual(Set(written.value).count, count)
    }
}
