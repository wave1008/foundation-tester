// ストレージ更新の進捗通知(monitorStorage): 積んだ瞬間に全台の「測定中」を出し、終わった台から「測り終えた」を出す。
// 周期の一覧を待つと、速い台(Android)の「測り終えた」だけが先に届き、拡張には測定中の台が無く見えた(ボタンが一瞬押せた)。

import FTCore
import XCTest

@testable import fleetest

final class StorageProgressBoardTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testScheduledDevicesAreAnnouncedAsMeasuringBeforeAnyFinishes() throws {
        let lines = BoardLines()
        let board = StorageProgressBoard(write: { lines.append($0) })
        let probe: DeviceStorageSampler.Probe = { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return DeviceStorageInfo(usedBytes: 1, freeBytes: 1, freeScope: .device, measuredAt: "t")
        }
        let sampler = DeviceStorageSampler(probeIOS: probe, probeAndroid: probe, storeURL: nil,
                                           onMeasured: { board.publish(key: $0) })
        board.attach(sampler)
        board.setDeviceIDs(["U": "ios:iPhone", "S": "android:Pixel"])
        board.setHandledRefreshId(7)
        sampler.requestRefresh()
        board.publish(keys: sampler.schedule(candidates: [("U", "ios"), ("S", "android")]))

        let announced = try lines.events()
        XCTAssertEqual(Set(announced.map(\.device)), ["ios:iPhone", "android:Pixel"])
        XCTAssertTrue(announced.allSatisfy { $0.storageMeasuring && $0.storageRefreshId == 7 },
                      "積んだ瞬間は全台「測定中」(速い台が終わる前に知らせる)")

        waitUntil { (try? lines.events().count) == 4 }
        let last = Dictionary(try lines.events().map { ($0.device, $0) }, uniquingKeysWith: { _, later in later })
        XCTAssertEqual(last["ios:iPhone"]?.storageMeasuring, false, "各台の最後の通知は「測り終えた」")
        XCTAssertEqual(last["android:Pixel"]?.storageMeasuring, false)
        XCTAssertEqual(last["ios:iPhone"]?.storage?.usedBytes, 1)
    }

    /// 周期の一覧に居ない台(id が引けない)は出さない
    func testUnknownDeviceIsNotPublished() {
        let lines = BoardLines()
        let board = StorageProgressBoard(write: { lines.append($0) })
        let sampler = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil }, storeURL: nil,
                                           onMeasured: { _ in })
        board.attach(sampler)
        board.publish(key: "gone")
        XCTAssertEqual(lines.count, 0)
    }
}

private final class BoardLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    func events() throws -> [ApiMonitorStorageEvent] {
        lock.lock(); let copy = items; lock.unlock()
        return try copy.map { try JSONDecoder().decode(ApiMonitorStorageEvent.self, from: Data($0.utf8)) }
    }
}
