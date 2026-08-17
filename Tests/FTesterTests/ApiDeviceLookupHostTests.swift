// `api device-up/down --name` がどのデバイスに当たるか。
//
// 実害(2026-08-17): フリートでは**同名の台が複数の機械にある**のが通常((host, name) が一意)。
// 名前だけで引くと最初の一致 = 手元の台に当たるので、**M1Max のタイルから停止したのに
// 手元のシミュレータが止まった**(しかも ok:true で「成功」に見えた)。
//
// 規律は2つ:
//  - `--device-host` を渡したら、**その機械の台だけ**を見る(他機の同名には当たらない)
//  - 渡さなかったら、**候補が1つのときだけ**採る。2つ以上なら候補を挙げて止める ——
//    黙って片方を選ぶと「別の機械のデバイスを操作した」になり、気づけない
//    (実行プロファイルの参照解決 `DeviceHostGrouping.resolve` と同じ規律)

import FTCore
import XCTest

@testable import ftester

final class ApiDeviceLookupHostTests: XCTestCase {

    private func spec(_ name: String, host: String?) -> DeviceSpec {
        var spec = DeviceSpec(name: name, os: "27.0")
        spec.host = host
        return spec
    }

    /// 同名の iPhone が3機に、Android は M1Max にだけ、という実物と同じ形
    private func machine() -> MachineProfile {
        MachineProfile(
            host: nil,
            ios: MachineDeviceList(devices: [
                spec("iPhone-01", host: "local"),
                spec("iPhone-01", host: "M1Max"),
                spec("iPhone-01", host: "M1Ultra"),
                spec("iPhone-99", host: nil),
            ]),
            android: MachineDeviceList(devices: [spec("Pixel-01", host: "M1Max")]))
    }

    func testHostGivenPicksThatMachinesDevice() {
        guard case .found(let spec, let platform) = ApiDeviceOperation.findDevice(
            name: "iPhone-01", deviceHost: "M1Max", in: machine())
        else { return XCTFail("M1Max の台が引けること") }
        XCTAssertEqual(spec.host, "M1Max")
        XCTAssertEqual(platform, "ios")
    }

    func testHostGivenNeverFallsBackToAnotherMachine() {
        guard case .missing = ApiDeviceOperation.findDevice(
            name: "Pixel-01", deviceHost: "local", in: machine())
        else { return XCTFail("手元に無い台を他機から拾ってはいけない") }
    }

    func testNoHostRefusesWhenTheNameExistsOnSeveralMachines() {
        guard case .ambiguous(let hosts) = ApiDeviceOperation.findDevice(
            name: "iPhone-01", deviceHost: nil, in: machine())
        else { return XCTFail("黙って手元を選ぶと『M1Max を止めたつもりで手元が止まる』になる") }
        XCTAssertEqual(hosts, ["local", "M1Max", "M1Ultra"], "どれなのか選べるよう候補を全部出す")
    }

    func testNoHostIsFineWhenTheNameIsUniqueAcrossMachines() {
        // 単一マシン構成(host を書いていない従来のプロファイル)はこの経路。挙動を変えない
        guard case .found(let spec, _) = ApiDeviceOperation.findDevice(
            name: "iPhone-99", deviceHost: nil, in: machine())
        else { return XCTFail("候補が1つなら従来どおり通る") }
        XCTAssertNil(spec.host)
    }

    func testExplicitLocalMatchesBothTheExplicitAndTheOmittedForm() {
        // マシンプロファイルの "local" 明示と host 省略は同じ「手元」を指す
        guard case .found(let spec, _) = ApiDeviceOperation.findDevice(
            name: "iPhone-99", deviceHost: "local", in: machine())
        else { return XCTFail("host 省略の台は --device-host local で引けること") }
        XCTAssertNil(spec.host)
    }
}
