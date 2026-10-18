// 計測 run の終わりに戻すアニメーション設定の決定(この run が書き換えたものだけ)。

import XCTest
@testable import FTAndroid
@testable import FTCore

final class AndroidAnimationRestoreTests: XCTestCase {

    private let keys = AnimationPolicy.androidScaleKeys

    func testRestoresOnlyKeysThatWereZeroWhenAnimationsAreForcedOn() {
        let previous = [keys[0]: "0\n", keys[1]: "1.0\n", keys[2]: "0.5\n"]
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: previous, animationsEnabled: true)
        XCTAssertEqual(out, [.init(key: keys[0], value: "0")])
    }

    func testUnsetKeyIsNotRestoredWhenAnimationsAreForcedOn() {
        // 未設定は既定の 1.0 = 既に目的の状態。この run は書き換えていない
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, "null\n") })
        XCTAssertEqual(AndroidAnimationSettings.restoreEntries(previousRaw: previous, animationsEnabled: true), [])
    }

    func testUnsetBecomesDeleteWhenAnimationsAreForcedOff() {
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: [keys[0]: "null\n"], animationsEnabled: false)
        XCTAssertEqual(out, [.init(key: keys[0], value: nil)])
        XCTAssertEqual(out[0].arguments, ["settings", "delete", "global", keys[0]])
    }

    func testKeysThatCouldNotBeReadAreNotRestored() {
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: [keys[1]: "0"], animationsEnabled: true)
        XCTAssertEqual(out.map(\.key), [keys[1]], "読めなかった key は元が分からないので戻さない")
        XCTAssertEqual(AndroidAnimationSettings.restoreEntries(previousRaw: [:], animationsEnabled: true), [])
    }

    func testPutArgumentsCarryThePreviousValueAndOrderFollowsPolicy() {
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, "0") })
        let out = AndroidAnimationSettings.restoreEntries(previousRaw: previous, animationsEnabled: true)
        XCTAssertEqual(out.map(\.key), keys)
        XCTAssertEqual(out[0].arguments, ["settings", "put", "global", keys[0], "0"])
    }
}
