// ref 指定の type / clear の「タップ後の受け口が叩いた要素のものか」(`FocusLanding.landed`)。
// 幾何は E2E-Flutter の入力画面の実測: 欄 #field_single (16,298 370x48)・#field_password (16,354 370x48)、
// Flutter の受け口は 1×1pt で欄の編集領域の左上((16,310) / (16,366))。容器は2つの欄を包む矩形で、
// その中心 (201,350) は2つの欄の間(346〜354)に落ちる = 叩いても焦点は動かない。
// **容器の形は自前の SUT の木に出ない**(Flutter の意味ノードは欄を包む容器を出さない)ので、ここでだけ縛る。

import XCTest
import CoreGraphics
@testable import FTCore

final class FocusLandingTests: XCTestCase {
    private let single = CGRect(x: 16, y: 298, width: 370, height: 48)
    private let password = CGRect(x: 16, y: 354, width: 370, height: 48)
    private let card = CGRect(x: 0, y: 290, width: 402, height: 120)
    private let singleReceiver = CGRect(x: 16, y: 310, width: 1, height: 1)
    private let passwordReceiver = CGRect(x: 16, y: 366, width: 1, height: 1)

    /// **本命**: パスワード欄に焦点を残して、2つの欄を包む容器を叩いた(焦点は動かない)→ 通さない
    func testAContainerHoldingThePreviouslyFocusedFieldIsNotALanding() {
        XCTAssertFalse(FocusLanding.landed(receiver: passwordReceiver, tapped: CGPoint(x: 201, y: 350),
                                           target: card, targetIsInput: false, movedSinceTap: false))
    }

    /// 包み(id を持つ行)を叩いて中の欄へ焦点が移った形は通す(受け口が動いた)
    func testAContainerWhoseTapMovedFocusInsideIsALanding() {
        XCTAssertTrue(FocusLanding.landed(receiver: singleReceiver, tapped: CGPoint(x: 201, y: 350),
                                          target: card, targetIsInput: false, movedSinceTap: true))
    }

    /// 焦点のある欄を叩き直した(受け口は動かない)形は、叩いたのが入力欄なら通す
    func testRetappingTheFocusedFieldIsALanding() {
        XCTAssertTrue(FocusLanding.landed(receiver: singleReceiver, tapped: CGPoint(x: 201, y: 322),
                                          target: single, targetIsInput: true, movedSinceTap: false))
    }

    /// 別の欄に焦点が残った(受け口が叩いた欄の外)形は、入力欄を叩いても通さない
    func testAReceiverOutsideTheTappedFieldIsNotALanding() {
        XCTAssertFalse(FocusLanding.landed(receiver: passwordReceiver, tapped: CGPoint(x: 201, y: 322),
                                           target: single, targetIsInput: true, movedSinceTap: false))
    }

    /// 叩いた要素の枠が取れないときは、面積の無い受け口は通さない(判断の材料が無い)
    func testAZeroAreaReceiverWithoutATargetFrameIsNotALanding() {
        XCTAssertFalse(FocusLanding.landed(receiver: singleReceiver, tapped: CGPoint(x: 201, y: 322),
                                           target: nil, targetIsInput: true, movedSinceTap: true))
    }

    /// 面積のある受け口(UIKit・Compose)は点で見る: 容器の枠の中でも点が欄の外なら通さない
    func testAnAreaReceiverIsJudgedByThePointOnly() {
        XCTAssertTrue(FocusLanding.landed(receiver: single, tapped: CGPoint(x: 201, y: 322),
                                          target: card, targetIsInput: false, movedSinceTap: false))
        XCTAssertFalse(FocusLanding.landed(receiver: password, tapped: CGPoint(x: 201, y: 350),
                                           target: card, targetIsInput: false, movedSinceTap: true))
    }
}
