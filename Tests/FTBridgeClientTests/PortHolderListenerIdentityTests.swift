// `.inapp` 台帳の生死を「誰かが待受しているか」だけで決めない(PortHolder.listenerIsAnotherSimulator)。
// 別のデバイスのブリッジが同じポートを取ると古い `.inapp` が生き続け、供給がそれを
// 「別アプリに注入された in-app ブリッジ」と読んで**無関係なデバイスのアプリを terminate** する
// (実地 2026-09-23 の負荷テスト)。
// **肯定的に別のシミュレータと読めた回だけ**外す —— 実機の in-app(iproxy が握る)や
// 形の分からない占有者は従来どおり「生きている」側へ倒す。

import XCTest
@testable import FTBridgeClient

final class PortHolderListenerIdentityTests: XCTestCase {

    private let recorded = "E38DCA93-95F2-4DDF-B1FE-29527205D3EE"
    private let other = "2A7FBD43-4A72-44DA-AB95-EED23B1B3B6D"

    func testAnotherSimulatorsAppIsRecognised() {
        let listener = "pid 123: /Users/x/Library/Developer/CoreSimulator/Devices/\(other)"
            + "/data/Containers/Bundle/Application/AAA/FTE2E.app/FTE2E"
        XCTAssertTrue(PortHolder.listenerIsAnotherSimulator(listener: listener, recordedUDID: recorded))
    }

    func testTheRecordedSimulatorIsNotForeign() {
        let listener = "pid 123: /Users/x/Library/Developer/CoreSimulator/Devices/\(recorded)"
            + "/data/Containers/Bundle/Application/AAA/FTE2E.app/FTE2E"
        XCTAssertFalse(PortHolder.listenerIsAnotherSimulator(listener: listener, recordedUDID: recorded))
    }

    /// 実機の in-app はポートを iproxy が握る(CoreSimulator のパスを持たない)。
    /// ここで true を返すと**生きている実機の台帳を消す**ので、分からない形は false
    func testIproxyAndUnknownShapesAreNotTreatedAsForeign() {
        XCTAssertFalse(PortHolder.listenerIsAnotherSimulator(
            listener: "pid 44710: /opt/homebrew/bin/iproxy 8123 8123 -u 00008110-000260242EEB801E",
            recordedUDID: recorded))
        XCTAssertFalse(PortHolder.listenerIsAnotherSimulator(listener: "pid 1: something",
                                                             recordedUDID: recorded))
    }
}

/// `PortHolder.udidFromListener`(B5): 応答しないポートの背後にデバイスが居ると分かれば、
/// `bridge down` は止める前に lease(run/MCP)を照合する。`RunnerDestination.udidTokens` を
/// 再利用するだけの純粋関数なので、境界は「識別子が読めるか」の1点だけ確かめる
final class PortHolderUDIDFromListenerTests: XCTestCase {

    /// シミュレータの XCUITest ランナー(実地の busy 台の形)
    func testReadsTheUDIDFromASimulatorRunnerCommandLine() {
        let listener = "pid 1: xcodebuild -destination platform=iOS Simulator,"
            + "id=E38DCA93-95F2-4DDF-B1FE-29527205D3EE -resultBundlePath /x"
        XCTAssertEqual(PortHolder.udidFromListener(listener),
                       "E38DCA93-95F2-4DDF-B1FE-29527205D3EE")
    }

    /// 実機の USB トンネル(iproxy)の形も読める
    func testReadsTheUDIDFromAnIproxyTunnelCommandLine() {
        let listener = "pid 3: /opt/homebrew/bin/iproxy 8123 8123 -u 00008110-000260242EEB801E"
        XCTAssertEqual(PortHolder.udidFromListener(listener), "00008110-000260242EEB801E")
    }

    /// listener が居ない(そもそも誰も listen していない)は nil ——
    /// 「分からないから断らない」に倒す(止める手段を奪わない)
    func testNoListenerYieldsNil() {
        XCTAssertNil(PortHolder.udidFromListener(nil))
    }

    /// 識別子が1つも出てこない占有者も nil(既存の RunnerDestination.udidTokens の性質を継ぐ)
    func testUnidentifiableListenerYieldsNil() {
        XCTAssertNil(PortHolder.udidFromListener("pid 4: /usr/bin/something"))
    }
}

/// `/status` が答えないポートの占有者が別のデバイスか(プロセスの実体から)。
/// **busy は正常**(XCUITest は駆動中に答えない)なので、**肯定的に別デバイスと読めたときだけ**
/// true —— ここを「待受している」だけで true にすると、自分の busy なブリッジを見捨てて
/// 2本目のランナーを立てる(同じ台に2本立つと先代が蹴り出される)
final class RunnerDestinationTokenTests: XCTestCase {

    func testTokensAreReadFromEveryShapeOfCommandLine() {
        let simulator = "pid 1: xcodebuild -destination platform=iOS Simulator,"
            + "id=E38DCA93-95F2-4DDF-B1FE-29527205D3EE -resultBundlePath /x"
        XCTAssertEqual(RunnerDestination.udidTokens(inCommand: simulator),
                       ["E38DCA93-95F2-4DDF-B1FE-29527205D3EE"])
        let inApp = "pid 2: /Users/x/Library/Developer/CoreSimulator/Devices/"
            + "2A7FBD43-4A72-44DA-AB95-EED23B1B3B6D/data/Containers/Bundle/Application/A/B.app/B"
        XCTAssertEqual(RunnerDestination.udidTokens(inCommand: inApp),
                       ["2A7FBD43-4A72-44DA-AB95-EED23B1B3B6D"])
        let tunnel = "pid 3: /opt/homebrew/bin/iproxy 8123 8123 -u 00008110-000260242EEB801E"
        XCTAssertEqual(RunnerDestination.udidTokens(inCommand: tunnel),
                       ["00008110-000260242EEB801E"])
    }

    /// 識別子が1つも出てこない占有者は「分からない」= 別デバイス扱いにしない
    func testNoTokensMeansUnknown() {
        XCTAssertTrue(RunnerDestination.udidTokens(inCommand: "pid 4: /usr/bin/something").isEmpty)
    }
}
