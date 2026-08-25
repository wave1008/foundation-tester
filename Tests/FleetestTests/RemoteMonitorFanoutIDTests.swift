// 子(ランナー)が名乗るタイル id を、親が (host, name) の id へ直すこと。
// **畳んだプロファイルを送る**(FTCore.RunnerProfileView)ので子は自分の台を "local" と名乗り、
// id にホストが入らない。直さないと状態も映像もタイルに届かない
// (実害 2026-08-26: 畳み込みを入れた直後、リモートのタイルが全部「状態不明」になった)。

import XCTest
import FTCore
@testable import fleetest

final class RemoteMonitorFanoutIDTests: XCTestCase {

    /// 子の monitorDevices は **id もマシンバッジ(machineHost)も持たない**(畳んだプロファイルでは
    /// 自分の台は "local")。親が両方を埋める —— 埋め忘れるとタイルが特定できない/バッジが消える
    func testRemoteDevicesGetBothTheScopedIDAndTheMachineBadge() throws {
        let line = #"""
        {"kind":"monitorDevices","devices":[{"id":"android:Pixel 3a","name":"Pixel 3a","platform":"android","state":"connected","detail":"S","udid":null,"serial":"S","health":null,"renderMode":null,"inRun":false,"kind":"physical","host":null,"port":null,"recording":false,"registered":true,"frozen":false,"machineHost":null}]}
        """#
        let fanout = RemoteMonitorFanout(hosts: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { _ in })
        fanout.ingest(line: line, host: "M1Ultra")
        let devices = fanout.snapshot()
        XCTAssertEqual(devices.keys.sorted(), ["android:M1Ultra/Pixel 3a"])
        XCTAssertEqual(devices["android:M1Ultra/Pixel 3a"]?.machineHost, "M1Ultra",
                       "マシンのバッジは親が入れる(子は自分を local と見なす)")
    }

    func testFrameLineGetsTheHostScopedDeviceID() {
        let line = #"{"kind":"monitorFrame","device":"android:Pixel 3a","jpegBase64":"AAAA","width":1}"#
        let scoped = RemoteMonitorFanout.hostScoped(line: line, host: "M1Ultra")
        XCTAssertEqual(
            scoped,
            #"{"kind":"monitorFrame","device":"android:M1Ultra/Pixel 3a","jpegBase64":"AAAA","width":1}"#)
        // 規則は DeviceHostGrouping.workerID(2つ目の実装を作らない)
        XCTAssertTrue(scoped.contains(
            DeviceHostGrouping.workerID(platform: "android", host: "M1Ultra", name: "Pixel 3a")))
    }

    /// **デバイス名が "/" を含むのは普通**(例 "Pixel 10(Android 14(API 34) / arm64-v8a)-01")。
    /// "/" の有無で「もうホスト付き」と判定すると、その台だけ id が直らず映像が届かない
    func testDeviceNameContainingSlashIsStillScoped() {
        let line = #"{"kind":"monitorFrame","device":"android:Pixel 10(API 34 / arm64)-01","jpegBase64":"A"}"#
        XCTAssertEqual(
            RemoteMonitorFanout.hostScoped(line: line, host: "M1Max"),
            #"{"kind":"monitorFrame","device":"android:M1Max/Pixel 10(API 34 / arm64)-01","jpegBase64":"A"}"#)
    }

    /// 既にこのホストで修飾済みの id は二重に付けない(冪等)
    func testAlreadyScopedIDIsLeftAlone() {
        let line = #"{"kind":"monitorFrame","device":"android:M1Max/Pixel 3a","jpegBase64":"A"}"#
        XCTAssertEqual(RemoteMonitorFanout.hostScoped(line: line, host: "M1Max"), line)
    }

    func testUnexpectedLinesPassThroughUnchanged() {
        for line in [#"{"kind":"monitorFrame"}"#, "not json", #"{"device":"noplatform"}"#] {
            XCTAssertEqual(RemoteMonitorFanout.hostScoped(line: line, host: "M1Max"), line, line)
        }
    }
}
