import XCTest
@testable import FTCore

/// 「この run の対象か」の仕分け。**対象外を runnable に混ぜると失敗として数えられ、
/// 逆に runnable を対象外へ落とすと1本も走らないまま緑になる**ので、両方向を固定する
final class PlatformApplicabilityTests: XCTestCase {

    private struct Item: Equatable {
        let id: String
        let platform: String?
    }

    private func partition(_ items: [Item],
                           _ runPlatforms: Set<String>) -> PlatformApplicability.Partition<Item> {
        PlatformApplicability.partition(items, runPlatforms: runPlatforms) { $0.platform }
    }

    func test宣言なしは常に対象() {
        let result = partition([Item(id: "a", platform: nil)], ["android"])
        XCTAssertEqual(result.runnable, [Item(id: "a", platform: nil)])
        XCTAssertTrue(result.notApplicable.isEmpty)
    }

    func test宣言がrunのOSに含まれれば対象() {
        let result = partition([Item(id: "a", platform: "android")], ["android"])
        XCTAssertEqual(result.runnable.map(\.id), ["a"])
        XCTAssertTrue(result.notApplicable.isEmpty)
    }

    func test宣言がrunのOSに無ければ対象外() {
        let result = partition([Item(id: "a", platform: "ios")], ["android"])
        XCTAssertTrue(result.runnable.isEmpty)
        XCTAssertEqual(result.notApplicable.map(\.id), ["a"])
    }

    func test両OSのプロファイルではどちらの宣言も対象() {
        let items = [Item(id: "a", platform: "ios"), Item(id: "b", platform: "android")]
        let result = partition(items, ["ios", "android"])
        XCTAssertEqual(result.runnable.map(\.id), ["a", "b"])
        XCTAssertTrue(result.notApplicable.isEmpty)
    }

    /// 「どの OS で回すか分からない」を「全部対象外」に倒すと、デバイス解決に失敗しただけの run が
    /// 1本も走らないまま緑になる。空集合は判定材料が無い = 素通し
    func testRunPlatformsが空なら全件対象のまま() {
        let items = [Item(id: "a", platform: "ios"), Item(id: "b", platform: nil)]
        let result = partition(items, [])
        XCTAssertEqual(result.runnable.map(\.id), ["a", "b"])
        XCTAssertTrue(result.notApplicable.isEmpty)
    }

    func test投入順は保たれる() {
        let items = [Item(id: "a", platform: "android"), Item(id: "b", platform: "ios"),
                     Item(id: "c", platform: nil), Item(id: "d", platform: "android")]
        let result = partition(items, ["android"])
        XCTAssertEqual(result.runnable.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(result.notApplicable.map(\.id), ["b"])
    }

    /// 理由は宣言側と run 側の両方を出す。片方だけだと「なぜ外れたか」がレポートから読めない
    func test理由は宣言したOSと回すOSを両方名指しする() {
        let reason = PlatformApplicability.reason(declared: "ios", runPlatforms: ["android"])
        XCTAssertTrue(reason.contains("ios"), reason)
        XCTAssertTrue(reason.contains("android"), reason)
    }

    func test理由は回すOSを昇順で並べる() {
        let reason = PlatformApplicability.reason(declared: "ios", runPlatforms: ["ios", "android"])
        XCTAssertTrue(reason.contains("android, ios"), reason)
    }
}
