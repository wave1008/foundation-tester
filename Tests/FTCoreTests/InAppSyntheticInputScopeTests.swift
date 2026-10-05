// in-app の合成入力の適用範囲を縛る。
// ①ref タップで activate 不発のとき 501 → XCUITest へ回すのは SwiftUI だけ(RN・自前描画・UIKit は合成タッチが効く)
// ②スクロールの delegate 通知を合成してよい相手(アプリ自身の delegate だけ)

import XCTest
import FTCore

final class InAppSyntheticInputScopeTests: XCTestCase {
    func testOnlySwiftUIRejectsSyntheticTap() {
        for framework in AppUIFramework.allCases {
            XCTAssertEqual(framework.rejectsSyntheticTap, framework == .swiftUI, "\(framework)")
        }
    }

    func testBridgeReadsTheGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(bridge.contains("rejectsSyntheticTap == true"))
        XCTAssertTrue(bridge.contains("ScrollDelegateNotification.shouldNotify("))
    }

    func testNotifiesAppDelegates() {
        XCTAssertTrue(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "E2EYApp.ChatViewController", scrollViewClassName: "UITableView"))
        XCTAssertTrue(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "_TtC9MySwiftUIApp8Delegate", scrollViewClassName: "UIScrollView"))
        XCTAssertTrue(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "RCTScrollView", scrollViewClassName: "RCTCustomScrollView"))
    }

    func testDoesNotNotifySwiftUIOrWebKitOrMissingDelegate() {
        XCTAssertFalse(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "SwiftUI.UIKitScrollViewDelegate", scrollViewClassName: "UIScrollView"))
        XCTAssertFalse(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "_TtC7SwiftUIP33_ABC12UIKitScrollViewDelegate", scrollViewClassName: "UIScrollView"))
        XCTAssertFalse(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "_TtGC7SwiftUI8Foo", scrollViewClassName: "UIScrollView"))
        XCTAssertFalse(ScrollDelegateNotification.shouldNotify(
            delegateClassName: "WKWebView", scrollViewClassName: "WKScrollView"))
        XCTAssertFalse(ScrollDelegateNotification.shouldNotify(
            delegateClassName: nil, scrollViewClassName: "UITableView"))
    }
}
