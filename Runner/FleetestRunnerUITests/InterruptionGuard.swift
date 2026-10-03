// InterruptionGuard.swift
// **XCTest の既定の割り込みハンドラを止める**(FleetestBridgeTests が起動時に1回 install)。
//
// 既定のハンドラは、操作が SpringBoard のアラートに遮られると**アラートのボタンを勝手に押し**
// (「許可しない」だけでなく「許可」も。2026-10-03 の負荷テストで実測)、**遮られた操作を撃ち直す**。
// これは「吸われた操作は撃ち直さない」「登録(iosAlertHandler)が無ければアラートは閉じない」に反する
// (CLAUDE.md・docs/design.md「登録の無いシステムアラート」)。
//
// 何もせず true を返すモニタを置くと、XCTest は約 7 秒モニタを呼び直したあと「Failed to handle UI
// interruptions」の issue を記録して**その操作を諦める**(ボタンは押されず、操作も合成されない —
// 実測)。issue は `FleetestBridgeTests.record` が握りつぶすので、**ここで控えて BridgeRouter が
// 422 で答える**(控えないと「何も起きていないのに 200」になる)。
// **モニタは false を返してはいけない** —— false は「このモニタは扱わない」で、既定のハンドラへ落ちる。

import Foundation
import XCTest

final class InterruptionGuard {
    static let shared = InterruptionGuard()

    struct Blocked {
        let title: String
        let buttons: [String]
    }

    /// main スレッドでしか触らない(要求の処理もモニタも main で動く。BridgeHTTPServer 参照)
    private var blocked: Blocked?

    func install(on testCase: XCTestCase) {
        testCase.addUIInterruptionMonitor(withDescription: "fleetest: leave system alerts untouched") { [weak self] alert in
            // XCTest は諦めるまで同じ要求の中で何十回も呼ぶ。ボタンの読みは最初の1回だけ
            if self?.blocked == nil {
                let buttons = alert.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
                self?.blocked = Blocked(title: alert.label, buttons: buttons)
                NSLog("[fleetest] a system alert blocked an action; left it untouched: %@", alert.label)
            }
            return true
        }
    }

    /// 要求の頭で呼ぶ(前の要求の控えを持ち越さない)
    func reset() { blocked = nil }

    /// この要求の間にアラートが操作を遮っていたら控えを返して消す
    func take() -> Blocked? {
        defer { blocked = nil }
        return blocked
    }

    /// 422 の本文。**押していない・撃ち直していない**ことと、閉じる手段を言う
    static func message(_ blocked: Blocked) -> String {
        let buttons = blocked.buttons.isEmpty ? "" : ", buttons: " + blocked.buttons.joined(separator: " / ")
        return "a system alert is in front of the app (title: \(blocked.title)\(buttons)), so this action"
            + " was not delivered — the alert was left as it is (no button was pressed and the action"
            + " was not retried). Close it first by tapping one of its buttons; in a scenario,"
            + " iosAlertHandler closes it automatically"
    }
}
