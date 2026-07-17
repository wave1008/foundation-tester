import XCTest
@testable import FTCore

final class ScenarioQueueTests: XCTestCase {

    private func makeItem(id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp", platform: "android"))
    }

    func testRequeueAllowsUpToCapThenReturnsNil() async {
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([])

        let first = await queue.requeue(item)
        XCTAssertEqual(first, 1)
        let second = await queue.requeue(item)
        XCTAssertNil(second, "上限(1 回)を超えたら再キューしない")
    }

    func testRequeueAppendsItemToQueue() async {
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([])
        let empty = await queue.next()
        XCTAssertNil(empty)

        _ = await queue.requeue(item)
        let requeued = await queue.next()
        XCTAssertEqual(requeued?.info.id, "Foo.bar")
    }

    func testRequeueTracksAttemptsPerItemIndependently() async {
        let itemA = makeItem(id: "Foo.a")
        let itemB = makeItem(id: "Foo.b")
        let queue = ScenarioQueue([])

        _ = await queue.requeue(itemA)
        _ = await queue.requeue(itemA)
        let bFirst = await queue.requeue(itemB)
        XCTAssertEqual(bFirst, 1, "別シナリオの再試行回数は独立してカウントされる")
    }

    func testHasItemsFalseWhenEmpty() async {
        let queue = ScenarioQueue([])
        let hasItems = await queue.hasItems()
        XCTAssertFalse(hasItems)
    }

    func testHasItemsTrueThenFalseAfterDrain() async {
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([item])

        let hasItems = await queue.hasItems()
        XCTAssertTrue(hasItems)

        _ = await queue.next()
        let drained = await queue.hasItems()
        XCTAssertFalse(drained)
    }
}
