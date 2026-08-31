// 子(ランナー)が名乗るタイル id を、親が (host, name) の id へ直すこと。
// **畳んだプロファイルを送る**(FTCore.RunnerProfileView)ので子は自分の台を "local" と名乗り、
// id にホストが入らない。直さないと状態も映像もタイルに届かない
// (実害 2026-08-26: 畳み込みを入れた直後、リモートのタイルが全部「状態不明」になった)。

import XCTest
import FTCore
import FTTestSupport
@testable import fleetest

final class RemoteMonitorFanoutIDTests: XCTestCase {

    /// 子の monitorDevices は **id もマシンバッジ(machine)も持たない**(畳んだプロファイルでは
    /// 自分の台は "local")。親が両方を埋める —— 埋め忘れるとタイルが特定できない/バッジが消える
    func testRemoteDevicesGetBothTheScopedIDAndTheMachineBadge() throws {
        let line = #"""
        {"kind":"monitorDevices","devices":[{"id":"android:Pixel 3a","name":"Pixel 3a","platform":"android","state":"connected","detail":"S","udid":null,"serial":"S","health":null,"renderMode":null,"inRun":false,"kind":"physical","host":null,"port":null,"recording":false,"registered":true,"frozen":false,"machine":null}]}
        """#
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { _ in })
        fanout.ingest(line: line, machine: "M1Ultra")
        let devices = fanout.snapshot()
        XCTAssertEqual(devices.keys.sorted(), ["android:M1Ultra/Pixel 3a"])
        XCTAssertEqual(devices["android:M1Ultra/Pixel 3a"]?.machine, "M1Ultra",
                       "マシンのバッジは親が入れる(子は自分を local と見なす)")
    }

    func testFrameLineGetsTheMachineScopedDeviceID() {
        let line = #"{"kind":"monitorFrame","device":"android:Pixel 3a","jpegBase64":"AAAA","width":1}"#
        let scoped = RemoteMonitorFanout.machineScoped(line: line, machine: "M1Ultra")
        XCTAssertEqual(
            scoped,
            #"{"kind":"monitorFrame","device":"android:M1Ultra/Pixel 3a","jpegBase64":"AAAA","width":1}"#)
        // 規則は DeviceMachineGrouping.workerID(2つ目の実装を作らない)
        XCTAssertTrue(scoped.contains(
            DeviceMachineGrouping.workerID(platform: "android", machine: "M1Ultra", name: "Pixel 3a")))
    }

    /// **デバイス名が "/" を含むのは普通**(例 "Pixel 10(Android 14(API 34) / arm64-v8a)-01")。
    /// "/" の有無で「もうホスト付き」と判定すると、その台だけ id が直らず映像が届かない
    func testDeviceNameContainingSlashIsStillScoped() {
        let line = #"{"kind":"monitorFrame","device":"android:Pixel 10(API 34 / arm64)-01","jpegBase64":"A"}"#
        XCTAssertEqual(
            RemoteMonitorFanout.machineScoped(line: line, machine: "M1Max"),
            #"{"kind":"monitorFrame","device":"android:M1Max/Pixel 10(API 34 / arm64)-01","jpegBase64":"A"}"#)
    }

    /// 既にこのホストで修飾済みの id は二重に付けない(冪等)
    func testAlreadyScopedIDIsLeftAlone() {
        let line = #"{"kind":"monitorFrame","device":"android:M1Max/Pixel 3a","jpegBase64":"A"}"#
        XCTAssertEqual(RemoteMonitorFanout.machineScoped(line: line, machine: "M1Max"), line)
    }

    /// 占有(monitorLock)も**マシン名は親が埋める**。埋め忘れると拡張がどの機械の占有か分からず、
    /// 配信の退避も占有表示も効かない(§18.2 M2)
    func testLockLineGetsTheMachineStamped() {
        let relayed = LockedBox<[String]>([])
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { line in relayed.mutate { $0.append(line) } })
        fanout.ingest(
            line: #"{"kind":"monitorLock","observed":true,"held":true,"issuer":"bob","issuerHost":"h","acquiredAt":"T","mine":false}"#,
            machine: "M1Ultra")
        // **添字で取らない** —— 変異で1行も出なくなったとき、クラッシュはこのプロセスの
        // 後続テストまで巻き添えにする(失敗で止まる形に保つ)
        let lines = relayed.value
        guard let line = lines.first, lines.count == 1 else {
            return XCTFail("expected exactly one relayed line: \(lines)")
        }
        XCTAssertTrue(line.contains(#""machine":"M1Ultra""#), line)
        XCTAssertTrue(line.contains(#""issuer":"bob""#), line)
        XCTAssertTrue(line.contains(#""held":true"#), line)
    }

    /// 子が落ちたら「もう観測できていない」を1行流す。**held:false を空きと読ませないため
    /// observed:false を添える**(拡張は控えを消して「不明」へ戻す)
    func testUnobservedLockLineIsRelayedWhenTheChildDies() {
        let relayed = LockedBox<[String]>([])
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { line in relayed.mutate { $0.append(line) } })
        fanout.relayUnobservedLock("M1Ultra")
        let lines = relayed.value
        guard let line = lines.first, lines.count == 1 else {
            return XCTFail("expected exactly one relayed line: \(lines)")
        }
        XCTAssertTrue(line.contains(#""observed":false"#), line)
        XCTAssertTrue(line.contains(#""machine":"M1Ultra""#), line)
    }

    func testUnexpectedLinesPassThroughUnchanged() {
        for line in [#"{"kind":"monitorFrame"}"#, "not json", #"{"device":"noplatform"}"#] {
            XCTAssertEqual(RemoteMonitorFanout.machineScoped(line: line, machine: "M1Max"), line, line)
        }
    }
}
