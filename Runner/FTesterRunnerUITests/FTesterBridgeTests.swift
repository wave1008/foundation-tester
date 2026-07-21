// FTesterBridgeTests.swift
// 「終わらないUIテスト」= ブリッジ本体。WebDriverAgent と同じ原理。
// xcodebuild test-without-building で起動し、SIGTERM されるまで常駐する。

import Foundation
import XCTest

final class FTesterBridgeTests: XCTestCase {

    func testRunBridgeServer() throws {
        // 個々の操作失敗(例: キーボード非表示での typeText)でテスト全体を
        // 落とさない。サーバは生き続ける。
        continueAfterFailure = true

        let portString = ProcessInfo.processInfo.environment["FT_PORT"] ?? ""
        let port = UInt16(portString) ?? BridgeAPI.defaultPort

        FastInput.installSwizzle()  // 高速入力(quiescence スキップ)。失敗しても通常動作
        let router = BridgeRouter()
        let server = BridgeHTTPServer(port: port) { router.handle($0) }
        try server.start()
        NSLog("[ftester] bridge listening on 127.0.0.1:%d", Int(port))

        // 接続処理は accept スレッドで行われる。ここでは RunLoop を回し続けて
        // テストを終わらせない(イベント合成等が必要とするランループも回る)。
        while server.isRunning {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
    }
}
