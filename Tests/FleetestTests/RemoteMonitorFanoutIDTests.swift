// 子(ランナー)が名乗るタイル id を、親が (host, name) の id へ直すこと。
// **畳んだプロファイルを送る**(FTCore.RunnerProfileView)ので子は自分の台を "local" と名乗り、
// id にホストが入らない。直さないと状態も映像もタイルに届かない
// (実害 2026-08-26: 畳み込みを入れた直後、リモートのタイルが全部「状態不明」になった)。

import XCTest
import FTCore
import FTRemote
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

    /// **手元の綴りは「machine 欄を出さない」**(monitorRuns / monitorDevices と同じ。拡張の
    /// runBoardModel.LOCAL_MACHINE_KEY へ写る)。ここで "local" のような別名を入れると、
    /// ①拡張のホスト負荷グラフの手元の行(キーは空文字)に錠前が付かない ②中継が上書きする
    /// 前提(RemoteMonitorFanout.ingest)と綴りが2通りになる
    func testLocalLockLineOmitsTheMachineField() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let occupancy = HostOccupancy(held: true, issuer: "alice", issuerHost: "dev-mbp",
                                      acquiredAt: "2026-09-21T00:00:00Z", mine: true)
        let line = String(decoding: try encoder.encode(ApiMonitorLockEvent(occupancy: occupancy)),
                          as: UTF8.self)
        XCTAssertFalse(line.contains("\"machine\""), line)
        XCTAssertTrue(line.contains(#""observed":true"#), line)
        XCTAssertTrue(line.contains(#""mine":true"#), line)
        // **中継はこの行をそのまま機械名付きに直せる**(片方だけ変えない)
        let relayed = LockedBox<[String]>([])
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { l in relayed.mutate { $0.append(l) } })
        fanout.ingest(line: line, machine: "M1Ultra")
        guard let stamped = relayed.value.first, relayed.value.count == 1 else {
            return XCTFail("expected exactly one relayed line: \(relayed.value)")
        }
        XCTAssertTrue(stamped.contains(#""machine":"M1Ultra""#), stamped)
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

    /// フリート横断の run 進捗(monitorRuns)も**マシン名は親が埋める**(docs/design.md §18.2)。
    /// 埋め忘れると、子は "local" を名乗ったまま届くので拡張が手元のタイルへ誤って重ねる
    func testRunsLineGetsTheMachineStamped() {
        let relayed = LockedBox<[String]>([])
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { line in relayed.mutate { $0.append(line) } })
        fanout.ingest(
            line: #"{"kind":"monitorRuns","observed":true,"runs":[{"pid":41233,"runID":"r1","runGroup":null,"issuer":"alice","mine":false,"project":"ec-mobile","profile":"ios-smoke","phase":"running","elapsedSeconds":10,"total":5,"done":1,"failed":0,"requeued":0,"laneDropouts":0,"etaSeconds":null,"lanes":[]}]}"#,
            machine: "M1Ultra")
        let lines = relayed.value
        guard let line = lines.first, lines.count == 1 else {
            return XCTFail("expected exactly one relayed line: \(lines)")
        }
        XCTAssertTrue(line.contains(#""machine":"M1Ultra""#), line)
        XCTAssertTrue(line.contains(#""runID":"r1""#), line)
    }

    /// 子が落ちたら run 進捗も「もう観測できていない」を1行流す(monitorLock と同じ規律。
    /// **held/run 無しと空きを混ぜない** —— 拡張は控えを消して不明に戻す)
    func testUnobservedRunsLineIsRelayedWhenTheChildDies() {
        let relayed = LockedBox<[String]>([])
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil,
                                         interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { line in relayed.mutate { $0.append(line) } })
        fanout.relayUnobservedRuns("M1Ultra")
        let lines = relayed.value
        guard let line = lines.first, lines.count == 1 else {
            return XCTFail("expected exactly one relayed line: \(lines)")
        }
        XCTAssertTrue(line.contains(#""observed":false"#), line)
        XCTAssertTrue(line.contains(#""machine":"M1Ultra""#), line)
        XCTAssertTrue(line.contains(#""runs":[]"#), line)
    }

    func testUnexpectedLinesPassThroughUnchanged() {
        for line in [#"{"kind":"monitorFrame"}"#, "not json", #"{"device":"noplatform"}"#] {
            XCTAssertEqual(RemoteMonitorFanout.machineScoped(line: line, machine: "M1Max"), line, line)
        }
    }
}
