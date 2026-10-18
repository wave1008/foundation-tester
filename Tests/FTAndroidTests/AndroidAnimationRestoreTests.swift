// 計測 run の終わりに戻すアニメーション設定の決定(読めた key はすべて)。

import XCTest
@testable import FTAndroid
@testable import FTCore

final class AndroidAnimationRestoreTests: XCTestCase {

    private let keys = AnimationPolicy.androidScaleKeys

    /// どの書き込み経路(コールド起動・同期)も3つ全部を書くので、既に目的の値の key も含めて元へ戻す
    func testRestoresEveryReadableKey() {
        let previous = [keys[0]: "0\n", keys[1]: "1.0\n", keys[2]: "0.5\n"]
        XCTAssertEqual(AndroidAnimationSettings.restoreEntries(previousRaw: previous),
                       [.init(key: keys[0], value: "0"), .init(key: keys[1], value: "1.0"),
                        .init(key: keys[2], value: "0.5")])
    }

    /// 1 / 0.5 / 未設定 は同期が何も違うと言わない値でも、コールド起動が 1/1/1 へ書き換える
    func testKeysAlreadyAtTheTargetAreRestoredToo() {
        let previous = [keys[0]: "1\n", keys[1]: "0.5\n", keys[2]: "null\n"]
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: previous)
        XCTAssertEqual(out, [.init(key: keys[0], value: "1"), .init(key: keys[1], value: "0.5"),
                             .init(key: keys[2], value: nil)])
        XCTAssertEqual(out[2].arguments, ["settings", "delete", "global", keys[2]])
    }

    func testKeysThatCouldNotBeReadAreNotRestored() {
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: [keys[1]: "0"])
        XCTAssertEqual(out.map(\.key), [keys[1]], "読めなかった key は元が分からないので戻さない")
        XCTAssertEqual(AndroidAnimationSettings.restoreEntries(previousRaw: [:]), [])
        let mixed = AndroidAnimationSettings.restoreEntries(previousRaw: [keys[0]: "0", keys[2]: "0.5"])
        XCTAssertEqual(mixed.map(\.key), [keys[0], keys[2]])
    }

    func testPutArgumentsCarryThePreviousValueAndOrderFollowsPolicy() {
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, "0") })
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: previous)
        XCTAssertEqual(out.map(\.key), keys)
        XCTAssertEqual(out[0].arguments, ["settings", "put", "global", keys[0], "0"])
    }
}
