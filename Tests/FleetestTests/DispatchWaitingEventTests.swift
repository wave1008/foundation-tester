// `fleetest api run --runner` が dispatch.lock の順番待ちを拡張へ見せる NDJSON イベント
// (ApiRunCommand.swift の ApiDispatchWaitingEvent / RemoteRunDispatcher.emitDispatchWaiting)。
// 対向は vscode-fleetest/src/model.ts の DispatchWaitingEvent と runReducer の "dispatchWaiting"。
// 落ちても run 自体は普通に走るので、E2E でも緑のまま「押した人には無言で止まって見える」に戻る。

import Foundation
import XCTest
@testable import fleetest

final class DispatchWaitingEventTests: XCTestCase {

    private func encoded(_ event: ApiDispatchWaitingEvent) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(event)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCarriesTheQueuePositionAndTheHolderWhenItWasRead() throws {
        let object = try encoded(ApiDispatchWaitingEvent(
            machine: "M1Max", position: 2, total: 3,
            holder: "issuer=taro pid=1234", elapsedSeconds: 60, limitSeconds: 900))
        XCTAssertEqual(object["kind"] as? String, "dispatchWaiting")
        XCTAssertEqual(object["machine"] as? String, "M1Max")
        XCTAssertEqual(object["position"] as? Int, 2)
        XCTAssertEqual(object["total"] as? Int, 3)
        XCTAssertEqual(object["holder"] as? String, "issuer=taro pid=1234")
        XCTAssertEqual(object["elapsedSeconds"] as? Int, 60)
        XCTAssertEqual(object["limitSeconds"] as? Int, 900)
    }

    /// **読めなかった保持者はキーごと省く** —— 空文字や "unknown" を入れると、拡張が
    /// 「誰かの run が走っている」と断定してしまう(不明と占有を混ぜない)
    func testOmitsTheHolderKeyEntirelyWhenItCouldNotBeRead() throws {
        let object = try encoded(ApiDispatchWaitingEvent(
            machine: "runner-2", position: 1, total: 2,
            holder: nil, elapsedSeconds: 0, limitSeconds: nil))
        XCTAssertNil(object["holder"], "nil は「占有」でも「空き」でもないのでキーごと出さない")
        XCTAssertNil(object["limitSeconds"], "--wait-lock 無しはキーごと出さない")
        XCTAssertEqual(object["elapsedSeconds"] as? Int, 0)
    }

    // MARK: - 配線(型では守れない: 出す刻みと出す経路)

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func dispatcherSource() throws -> String {
        try source("Sources/fleetest/RemoteRunDispatcher.swift")
    }

    /// **ログを出す条件とイベントを出す条件は同じ式**(判断を2つ持たない)。別々の if に割ると、
    /// 片方の刻みだけを変えたときに端末と拡張で見える回数が食い違う
    func testTheEventIsEmittedByTheSameConditionAsTheProgressLog() throws {
        let source = try Self.dispatcherSource()
        let calls = source.components(separatedBy: "emitDispatchWaiting(status)").count - 1
        XCTAssertEqual(calls, 1, "呼び出しは待機ループの1箇所だけ")
        let guardRange = try XCTUnwrap(
            source.range(of: "if WaitLockPolling.shouldLogProgress(elapsedSeconds: elapsed) {"),
            "進行ログの条件が見つからない")
        let callRange = try XCTUnwrap(source.range(of: "emitDispatchWaiting(status)"))
        XCTAssertLessThan(guardRange.lowerBound, callRange.lowerBound)
        let between = String(source[guardRange.upperBound..<callRange.lowerBound])
        XCTAssertFalse(between.contains("}"),
                       "log とイベントの間にブロックが閉じている = 条件を2つ持っている")
        XCTAssertTrue(between.contains("log("), "同じブロックで進行ログも出すこと")
    }

    /// cliRun(人間向け stdout)へ NDJSON を混ぜない —— 混ぜると `fleetest run --runner` の
    /// 端末出力に機械可読行が紛れる
    func testTheEmitterIsGuardedToTheApiRunModeOnly() throws {
        let source = try Self.dispatcherSource()
        let bodyStart = try XCTUnwrap(
            source.range(of: "private func emitDispatchWaiting(_ status: DispatchWaitStatus) {"))
        let body = String(source[bodyStart.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("guard mode == .apiRun else { return }"),
                      "apiRun のときだけ出すこと: \(body)")
    }

    // MARK: - 手元のロック(同じイベントを同じ刻みで出す)

    /// リモートと同じ規律を `LocalDispatchLock` にも掛ける —— **ログとイベントは同じ if**。
    /// 別々の if に割ると、手元の待機だけ端末と拡張で見える回数が食い違う
    func testTheLocalLockEmitsTheEventFromTheSameConditionAsItsProgressLog() throws {
        let source = try Self.source("Sources/fleetest/LocalDispatchLock.swift")
        let calls = source.components(separatedBy: "emitDispatchWaiting(status)").count - 1
        XCTAssertEqual(calls, 1, "呼び出しは待機ループの1箇所だけ")
        let guardRange = try XCTUnwrap(
            source.range(of: "if WaitLockPolling.shouldLogProgress(elapsedSeconds: elapsed) {"),
            "進行ログの条件が見つからない")
        let callRange = try XCTUnwrap(source.range(of: "emitDispatchWaiting(status)"))
        XCTAssertLessThan(guardRange.lowerBound, callRange.lowerBound)
        let between = String(source[guardRange.upperBound..<callRange.lowerBound])
        XCTAssertFalse(between.contains("}"),
                       "log とイベントの間にブロックが閉じている = 条件を2つ持っている")
        XCTAssertTrue(between.contains("log("), "同じブロックで進行ログも出すこと")
    }

    /// **出すのは `fleetest api run` の経路だけ** —— `fleetest run` の stdout は人間向けなので
    /// 機械可読行を混ぜない。両方向を見る(片方に渡し忘れ / 両方に渡す のどちらも落とす)
    func testOnlyTheApiRunEntryPointInjectsTheEmitter() throws {
        let api = try Self.source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertTrue(api.contains("emitWaiting: LocalDispatchLock.apiRunWaitingEmitter()"),
                      "api run が NDJSON の出し口を渡していない(拡張には無言で止まって見える)")
        let cli = try Self.source("Sources/fleetest/Fleetest.swift")
        XCTAssertFalse(cli.contains("emitWaiting:"),
                       "fleetest run の人間向け stdout に NDJSON を混ぜている")
    }

    /// 組み立ては**1箇所だけ** —— リモートと手元で別々にエンコードすると、欄を足したときに
    /// 片方だけ古い形を出す(拡張からは片方の機械の待機が黙って見えなくなる)
    func testBothCallersGoThroughTheOneEncoder() throws {
        for path in ["Sources/fleetest/RemoteRunDispatcher.swift",
                     "Sources/fleetest/LocalDispatchLock.swift"] {
            let text = try Self.source(path)
            XCTAssertTrue(text.contains("ApiDispatchWaitingEvent.emit("),
                          "\(path): 共有の組み立て口を通っていない")
            XCTAssertFalse(text.contains("ApiDispatchWaitingEvent("),
                           "\(path): イベントを自分で組み立てている(2つ目の実装)")
        }
    }
}
