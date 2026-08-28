import XCTest
@testable import fleetest

/// 子(リモート機の `api devices-up` / `devices-down`)は `--device-machine local` で走るので
/// 自分の台を machine:null と名乗る。**親が machine を入れる**ことを固定する ——
/// 入れないと受け手が同名の手元のタイルを書き換え、機械ごとに2台ずつ起きていても
/// 「全体で2台しか起動していない」ように見える。
final class RemoteDeviceFanoutTests: XCTestCase {

    private func decoded(_ line: String?) -> [String: Any] {
        guard let line, let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("not a JSON object: \(line)")
            return [:]
        }
        return object
    }

    func testStampsMachineOnEveryPerDeviceKind() {
        for kind in ["deviceStarting", "deviceStopping", "deviceFinished"] {
            let line = #"{"kind":"\#(kind)","machine":null,"name":"iPhone 17 Pro-01","platform":"ios"}"#
            let stamped = RemoteDeviceFanout.machineStamped(line: line, machine: "M1Max")
            let object = decoded(stamped)
            XCTAssertEqual(object["machine"] as? String, "M1Max", kind)
            XCTAssertEqual(object["name"] as? String, "iPhone 17 Pro-01", kind)
            XCTAssertEqual(object["platform"] as? String, "ios", kind)
            XCTAssertEqual(object["kind"] as? String, kind)
        }
    }

    /// 対象の集合を等号で固定する(per-device の種別を足したら machine を入れ忘れないため)
    func testPerDeviceKindsAreExactlyTheThreeLifecycleEvents() {
        XCTAssertEqual(RemoteDeviceFanout.deviceKinds,
                       ["deviceStopping", "deviceStarting", "deviceFinished"])
    }

    /// machine キーごと欠けている行(旧い子)にも入れる
    func testStampsMachineWhenTheKeyIsAbsent() {
        let line = #"{"kind":"deviceStarting","name":"Pixel 10-01","platform":"android"}"#
        let object = decoded(RemoteDeviceFanout.machineStamped(line: line, machine: "M1Ultra"))
        XCTAssertEqual(object["machine"] as? String, "M1Ultra")
    }

    /// log 行はどの機械の声か分かるようにする(手元の行と混ざると並列を確認できない)
    func testPrefixesLogMessagesWithTheMachine() {
        let line = #"{"kind":"log","message":"✅ iPhone 17 Pro-01: started"}"#
        let object = decoded(RemoteDeviceFanout.machineStamped(line: line, machine: "M1Max"))
        XCTAssertEqual(object["message"] as? String, "[M1Max] ✅ iPhone 17 Pro-01: started")
        XCTAssertNil(object["machine"], "log 行は machine を持たない契約(拡張は message だけ読む)")
    }

    /// 子の `finished` は「1機械ぶんの締め」——  流すとストリームに終端が機械の数だけ並ぶ
    /// (受け手の契約は「最後に1つ」。親が fan-out の完走後に出す)
    func testDropsTheChildTerminalEvent() {
        let line = #"{"error":null,"kind":"finished","ok":true}"#
        XCTAssertNil(RemoteDeviceFanout.machineStamped(line: line, machine: "M1Max"))
    }

    /// ただし**失敗は捨てない** —— 捨てるとその機械が丸ごと起きなかった理由が stdout から消える
    func testTurnsAChildFailureIntoALogLine() {
        let line = #"{"error":"no simulator with that UDID","kind":"finished","ok":false}"#
        let object = decoded(RemoteDeviceFanout.machineStamped(line: line, machine: "M1Ultra"))
        XCTAssertEqual(object["kind"] as? String, "log")
        XCTAssertEqual(object["message"] as? String, "❌ [M1Ultra] no simulator with that UDID")
    }

    /// error が無い失敗でも黙らない(理由が書けないだけで、起きなかったことは言う)
    func testStillReportsAFailureWithoutAnErrorMessage() {
        let line = #"{"error":null,"kind":"finished","ok":false}"#
        let object = decoded(RemoteDeviceFanout.machineStamped(line: line, machine: "M1Max"))
        XCTAssertEqual(object["message"] as? String,
                       "❌ [M1Max] the devices on this machine did not start")
    }

    /// 想定外の形は解釈せずそのまま流す(中継が行を落とさない)
    func testPassesThroughLinesItCannotUnderstand() {
        for line in [#"{"kind":"somethingNew","name":"x"}"#, "not json at all", "[1,2,3]",
                     #"{"message":"no kind"}"#] {
            XCTAssertEqual(RemoteDeviceFanout.machineStamped(line: line, machine: "M1Max"), line, line)
        }
        // 中継が行を落とすのは finished(ok:true)だけ、という等号
        XCTAssertNotNil(RemoteDeviceFanout.machineStamped(
            line: #"{"kind":"log","message":"x"}"#, machine: "M1Max"))
    }

    /// スラッシュを含むデバイス名(Android の AVD 表示名は普通に含む)が \/ へ潰れない ——
    /// 受け手はタイルを名前で引くので、エスケープが変わると一致しなくなる
    func testKeepsSlashesInNamesUnescaped() throws {
        let name = "Pixel 10(Android 14(API 34) / arm64-v8a)-01"
        let line = #"{"kind":"deviceStarting","machine":null,"name":"\#(name)","platform":"android"}"#
        let stamped = try XCTUnwrap(
            RemoteDeviceFanout.machineStamped(line: line, machine: "M1Ultra"))
        XCTAssertFalse(stamped.contains("\\/"), stamped)
        XCTAssertEqual(decoded(stamped)["name"] as? String, name)
    }
}
