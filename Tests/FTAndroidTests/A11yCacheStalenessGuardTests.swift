// 読み直しの後の素取得を確かめる規則(A11yCacheStalenessGuard)。witness: E2EY-CMP の折りたたみヘッダを Pixel 3a(API 32)で
// 回すと、探索の直後のタブのタップが払う前の座標を撃った(4/4。ブリッジの clearCache は API 34+ だけ)

import XCTest
import FTCore
@testable import FTAndroid

final class A11yCacheStalenessGuardTests: XCTestCase {

    private func tree(rowY: Double) -> String {
        A11yCacheStalenessGuard.signature([
            ElementInfo(ref: 1, type: "clickable", identifier: "tab_likes", label: "いいね", value: nil,
                        placeholder: nil, enabled: true, frame: FTRect(x: 720, y: rowY, width: 360, height: 81), depth: 1)
        ])
    }

    func testNoConfirmationBeforeAnyRefresh() {
        var guardState = A11yCacheStalenessGuard()
        XCTAssertFalse(guardState.plainReadNeedsConfirmation(tree(rowY: 1076)))
    }

    func testPlainReadMatchingTheRefreshClearsTheSuspicionWithoutAnotherRead() {
        var guardState = A11yCacheStalenessGuard()
        guardState.noteRefreshed(tree(rowY: 551))
        XCTAssertFalse(guardState.plainReadNeedsConfirmation(tree(rowY: 551)))
        XCTAssertNil(guardState.lastRefreshedSignature)
        XCTAssertFalse(guardState.plainReadNeedsConfirmation(tree(rowY: 1076)), "疑いが解けた後は確かめない")
    }

    /// 実測の形: 読み直しはヘッダが縮んだ位置(551)、素取得は払う前の位置(1076)
    func testStalePlainReadIsReplacedAndTheSuspicionStays() {
        var guardState = A11yCacheStalenessGuard()
        guardState.noteRefreshed(tree(rowY: 551))
        XCTAssertTrue(guardState.plainReadNeedsConfirmation(tree(rowY: 1076)))
        XCTAssertTrue(guardState.confirm(plain: tree(rowY: 1076), refreshed: tree(rowY: 551)))
        XCTAssertNotNil(guardState.lastRefreshedSignature, "キャッシュが古いままなら次の素取得も確かめる")
    }

    /// 画面が正当に変わった(素取得も読み直しも新しい木で一致)なら、素取得の木を使い疑いを解く
    func testScreenThatReallyChangedClearsTheSuspicion() {
        var guardState = A11yCacheStalenessGuard()
        guardState.noteRefreshed(tree(rowY: 551))
        XCTAssertTrue(guardState.plainReadNeedsConfirmation(tree(rowY: 600)))
        XCTAssertFalse(guardState.confirm(plain: tree(rowY: 600), refreshed: tree(rowY: 600)))
        XCTAssertNil(guardState.lastRefreshedSignature)
    }
}
