// FleetestBridgeTests.swift
// 「終わらないUIテスト」= ブリッジ本体。WebDriverAgent と同じ原理。
// xcodebuild test-without-building で起動し、SIGTERM されるまで常駐する。

import Foundation
import XCTest

final class FleetestBridgeTests: XCTestCase {

    func testRunBridgeServer() throws {
        // 個々の操作失敗(例: キーボード非表示での typeText)でテスト全体を
        // 落とさない。サーバは生き続ける。
        continueAfterFailure = true

        let portString = ProcessInfo.processInfo.environment["FT_PORT"] ?? ""
        let port = UInt16(portString) ?? BridgeAPI.defaultPort

        FastInput.installSwizzle()  // 高速入力(quiescence スキップ)。失敗しても通常動作
        let router = BridgeRouter()
        let server = BridgeHTTPServer(port: port) { router.handle($0) }
        router.idleSecondsProvider = { [weak server] in server?.idleBeforeLastRequest ?? 0 }
        try server.start()
        // 実機は FT_BIND_ALL=1 で 0.0.0.0 に開く(BridgeHTTPServer.start 参照)。
        // 127.0.0.1 決め打ちで出すと実機の切り分け時に誤誘導する
        let bindHost = ProcessInfo.processInfo.environment["FT_BIND_ALL"] == "1" ? "0.0.0.0" : "127.0.0.1"
        // 無通信 TTL(0 = 無期限)。忘れられたブリッジのデバイス占有を防ぐ(design.md §4.1)
        let ttl = BridgeAPI.resolvedBridgeTTLSeconds(ProcessInfo.processInfo.environment["FT_BRIDGE_TTL"])
        NSLog("[fleetest] bridge listening on %@:%d ttl=%@", bindHost, Int(port),
              ttl > 0 ? "\(ttl)s" : "off")

        // 画面が進んでいるかの計器(/status の displayIdleSeconds)。**RunLoop を回し始める前に**
        // 載せる —— 下のループが回り出さないと CADisplayLink は tick しない
        DisplayHeartbeat.shared.start()

        // 接続処理は accept スレッドで行われる。ここでは RunLoop を回し続けて
        // テストを終わらせない(イベント合成等が必要とするランループも回る)。
        while server.isRunning {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            if ttl > 0, server.idleSeconds > TimeInterval(ttl) {
                NSLog("[fleetest] bridge idle %.0fs > ttl %ds; self-terminating",
                      server.idleSeconds, ttl)
                server.stop()
            }
        }
    }
}
