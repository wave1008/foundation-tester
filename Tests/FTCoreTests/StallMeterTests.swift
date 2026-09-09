// StallMeter は「プロセスごと止まっていたか」を心拍で外から見る計器(StallMeter の doc)。
// ここが守るのは2つ: **普通のゆらぎを停止と呼ばない**ことと、**実際に止めたら計上される**こと。

import Foundation
import XCTest
@testable import FTCore

final class StallMeterTests: XCTestCase {

    /// 刻みそのものは数えない —— 数えるのは**予定より遅れたぶん**だけ。
    /// ここを「経過時間の合計」にすると、健全な run でも心拍のたびに数字が伸びて意味を失う
    func testNormalTicksAreNotCountedAsStall() {
        let meter = StallMeter()
        let before = meter.threadStallMilliseconds
        meter.record(overshoot: .milliseconds(StallMeter.ignoreBelowMilliseconds - 1), pool: false)
        XCTAssertEqual(meter.threadStallMilliseconds, before, "ゆらぎを停止に数えている")
    }

    /// 閾値を超えた遅れは、その**遅れたぶんだけ**計上される(刻みの分を足さない)
    func testOvershootIsAccumulated() {
        let meter = StallMeter()
        let before = meter.threadStallMilliseconds
        meter.record(overshoot: .milliseconds(700), pool: false)
        XCTAssertEqual(meter.threadStallMilliseconds - before, 700)
    }

    /// 2本の心拍は**別々に**数える —— 混ぜると「プロセスごと停止」と
    /// 「協調スレッドプールだけ詰まり」が区別できず、直す場所が決まらない
    func testThreadAndPoolAreCountedSeparately() {
        let meter = StallMeter()
        let thread = meter.threadStallMilliseconds
        let pool = meter.poolStallMilliseconds
        meter.record(overshoot: .milliseconds(500), pool: true)
        XCTAssertEqual(meter.threadStallMilliseconds, thread, "プールの遅れがスレッド側に混ざった")
        XCTAssertEqual(meter.poolStallMilliseconds - pool, 500)
    }

    /// 実際にプロセスを止めたら心拍が計上されること(心拍が本当に回っている証拠)。
    /// **SIGSTOP は使わない**(自分を止めると再開させる者が居ない)—— 協調スレッドプールを
    /// 全部ふさぐ形で、プール側の心拍が遅れることを確かめる
    func testPoolHeartbeatDetectsABlockedCooperativePool() throws {
        StallMeter.shared.startIfNeeded()
        let meter = StallMeter.shared
        // 心拍が1周する余裕を与える
        Thread.sleep(forTimeInterval: 0.3)
        let before = meter.poolStallMilliseconds
        // 協調スレッドプールの全スレッドを同期的にふさぐ(cooperative thread をブロックする形)
        let width = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<width {
            Task.detached(priority: .userInitiated) {
                // **協調スレッドを同期的に塞ぐ**のがこのテストの目的なので Task.sleep にしない
                // (Thread.sleep / semaphore.wait は async 文脈で使用不可の診断が出るため usleep)
                usleep(1_000_000)
                done.signal()
            }
        }
        for _ in 0..<width { _ = done.wait(timeout: .now() + 20) }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThan(meter.poolStallMilliseconds - before, 0,
                             "協調スレッドプールを塞いだのにプール側の心拍が遅れていない")
    }
}
