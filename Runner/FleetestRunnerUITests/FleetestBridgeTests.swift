// FleetestBridgeTests.swift
// 「終わらないUIテスト」= ブリッジ本体。WebDriverAgent と同じ原理。
// xcodebuild test-without-building で起動し、SIGTERM されるまで常駐する。

import Foundation
import XCTest

final class FleetestBridgeTests: XCTestCase {

    /// **XCUI の操作の失敗をテストの失敗として記録しない**(ログにだけ残す)。記録すると1件でも Tear Down して
    /// ランナーごとブリッジが消える(2026-09-19: WebView の中身を入力の途中で止め、消えた欄へ撃った typeText の
    /// 失敗1件で Tear Down。毎回再現)。このテストの成否に意味は無く(ブリッジの寿命そのもの)、操作の失敗は
    /// 各ハンドラが HTTP のエラーとしてホストへ返す。`continueAfterFailure` だけでは止まらない
    override func record(_ issue: XCTIssue) {
        NSLog("[fleetest] XCTest issue not recorded (the bridge keeps running): %@", issue.compactDescription)
    }

    func testRunBridgeServer() throws {
        // 個々の操作失敗(例: キーボード非表示での typeText)でテスト全体を
        // 落とさない。サーバは生き続ける。
        continueAfterFailure = true
        // LAN の実機では標準出力(XCTest の活動ログ)がネットワーク越しに転送され、回線の揺れで
        // 転送路が切れた直後の出力が SIGPIPE でランナーごと落としていた(2026-09-18 実測:
        // "Test crashed with signal pipe" が 1 run に 3 回。HTTP のソケットは SO_NOSIGPIPE 済み)。
        // ランナーは専用プロセスなので全体で無視し、書き込みは EPIPE で受ける
        signal(SIGPIPE, SIG_IGN)

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
        // **非公開 API が消えたら起動時に分かるようにする**(CoordinatePinch の doc)。
        // 無いと pinch が「手前のシートに1本を取られてパンになる」形へ静かに戻り、
        // doubletap は `XCUICoordinate.doubleTap()`(React Native では拾われない単タッチ)へ戻る。
        // `/gesture` にはフォールバックが無い(消えていれば 422 で断る)ので、消えたことは
        // ここで先に言っておく
        NSLog("[fleetest] coordinate pinch/gesture/doubletap: %@",
              CoordinatePinch.isAvailable ? "available"
                  : "UNAVAILABLE — this Xcode has no XCPointerEventPath; a pinch will fall back to the"
                    + " element pinch and may pan instead, doubletap falls back to a single XCTest"
                    + " touch, and /gesture has no fallback (422)")

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
