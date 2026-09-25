// `api start-device/down --name` がどのデバイスに当たるか。
//
// 実害(2026-08-17): フリートでは**同名の台が複数の機械にある**のが通常((host, name) が一意)。
// 名前だけで引くと最初の一致 = 手元の台に当たるので、**M1Max のタイルから停止したのに
// 手元のシミュレータが止まった**(しかも ok:true で「成功」に見えた)。
//
// 実害(2026-09-25・G13): `findDevice` は (machine, name) を正しく解決しても、
// **呼び出し側(ApiDeviceOperation.run / ApiRestartDevicesCommand)は常にこの機械で
// 操作を実行する**(ssh 越しに投げる経路を持たない)。解決した台が他の機械のものでも
// `.found` を返していたため、`--device-machine M1Max` を渡すと M1Max の台の**設定**で
// **この Mac の同名の台**を操作してしまっていた(Android は AVD 名が機械を跨いで同じなので、
// iOS と違い UDID 不一致で無害に失敗しない)。`.ambiguous` の案内がまさにこの
// `--device-machine` を勧めていたため、案内どおりに従うと事故る形だった。
//
// 規律は3つ:
//  - `--device-machine` を渡したら、**その機械の台だけ**を見る(他機の同名には当たらない)
//  - 渡さなかったら、**候補が1つのときだけ**採る。2つ以上なら候補を挙げて止める ——
//    黙って片方を選ぶと「別の機械のデバイスを操作した」になり、気づけない
//    (実行プロファイルの参照解決 `DeviceMachineGrouping.resolve` と同じ規律)
//  - **解決した台が手元(machine が nil)でなければ `.found` を返さない** ——
//    どちらの経路(明示 / 省略して一意)で解決したかに関わらず `.foreign` で断る

import FTCore
import XCTest

@testable import fleetest

final class ApiDeviceLookupHostTests: XCTestCase {

    private func spec(_ name: String, host: String?) -> DeviceSpec {
        var spec = DeviceSpec(name: name, osVersion: "27.0")
        spec.machine = host
        return spec
    }

    /// 同名の iPhone が3機に、Android は M1Max にだけ、という実物と同じ形
    private func machine() -> DeviceRoster {
        DeviceRoster(
            ios: DeviceRosterList(devices: [
                spec("iPhone-01", host: "local"),
                spec("iPhone-01", host: "M1Max"),
                spec("iPhone-01", host: "M1Ultra"),
                spec("iPhone-99", host: nil),
            ]),
            android: DeviceRosterList(devices: [spec("Pixel-01", host: "M1Max")]))
    }

    /// **G13**: `--device-machine M1Max` を明示しても、その機械の台をこの機械で
    /// 実行してはならない —— `.found` ではなく `.foreign` で断る(body は呼ばれない)
    func testHostGivenRefusesThatMachinesDeviceAsForeign() {
        guard case .foreign(let host, let spec, let platform) = ApiDeviceOperation.findDevice(
            name: "iPhone-01", deviceMachine: "M1Max", in: machine())
        else { return XCTFail("M1Max の台は .foreign で断ること(.found にしない)") }
        XCTAssertEqual(host, "M1Max")
        XCTAssertEqual(spec.machine, "M1Max")
        XCTAssertEqual(platform, "ios")
    }

    func testHostGivenNeverFallsBackToAnotherMachine() {
        guard case .missing = ApiDeviceOperation.findDevice(
            name: "Pixel-01", deviceMachine: "local", in: machine())
        else { return XCTFail("手元に無い台を他機から拾ってはいけない") }
    }

    func testNoHostRefusesWhenTheNameExistsOnSeveralMachines() {
        guard case .ambiguous(let machines) = ApiDeviceOperation.findDevice(
            name: "iPhone-01", deviceMachine: nil, in: machine())
        else { return XCTFail("黙って手元を選ぶと『M1Max を止めたつもりで手元が止まる』になる") }
        XCTAssertEqual(machines, ["local", "M1Max", "M1Ultra"], "どれなのか選べるよう候補を全部出す")
    }

    /// **G13 同型**: `--device-machine` 省略でも、候補が1つしかなければ黙って `.found` にしていた。
    /// その1つが他機の台なら(Android の AVD 名は機械を跨いで同名になりうる)、同名の手元の台を
    /// 他機の設定で操作してしまう —— 候補が1つでも手元でなければ `.foreign` で断る
    func testNoHostStillRefusesTheUniqueCandidateWhenItIsOnAnotherMachine() {
        guard case .foreign(let host, let spec, let platform) = ApiDeviceOperation.findDevice(
            name: "Pixel-01", deviceMachine: nil, in: machine())
        else { return XCTFail("候補が1つでも他機なら .foreign で断ること") }
        XCTAssertEqual(host, "M1Max")
        XCTAssertEqual(spec.machine, "M1Max")
        XCTAssertEqual(platform, "android")
    }

    func testNoHostIsFineWhenTheNameIsUniqueAcrossMachines() {
        // 単一マシン構成(machine を書いていない従来のプロファイル)はこの経路。挙動を変えない
        guard case .found(let spec, _) = ApiDeviceOperation.findDevice(
            name: "iPhone-99", deviceMachine: nil, in: machine())
        else { return XCTFail("候補が1つなら従来どおり通る") }
        XCTAssertNil(spec.machine)
    }

    func testExplicitLocalMatchesBothTheExplicitAndTheOmittedForm() {
        // マシンプロファイルの "local" 明示と host 省略は同じ「手元」を指す
        guard case .found(let spec, _) = ApiDeviceOperation.findDevice(
            name: "iPhone-99", deviceMachine: "local", in: machine())
        else { return XCTFail("host 省略の台は --device-machine local で引けること") }
        XCTAssertNil(spec.machine)
    }

    // MARK: - .foreign / .ambiguous の断り文言(純粋関数。呼び出し元ごとに subcommand が変わるので
    // 「貼って撃てる」代替コマンドの文字列まで確かめる)

    func testForeignMachineMessageNamesTheMachineAndTheRemoteExecCommand() {
        let message = ApiDeviceOperation.foreignMachineMessage(
            subcommand: "start-device", name: "iPhone-01", machine: "M1Max",
            project: "default", profile: "smoke")
        XCTAssertTrue(message.contains("M1Max"), "機械名を言う: \(message)")
        XCTAssertTrue(message.contains(
            "fleetest remote exec M1Max -- api start-device --name \"iPhone-01\""
            + " --project \"default\" --profile \"smoke\" --device-machine local"),
            "貼って撃てる代替コマンドを言う(--device-machine local。エイリアスをリモートへ出さない規律どおり): \(message)")
    }

    func testForeignMachineMessageOmitsUnsetOptionalArgs() {
        let message = ApiDeviceOperation.foreignMachineMessage(
            subcommand: "stop-device", name: "Pixel-01", machine: "M1Ultra",
            project: nil, profile: nil)
        XCTAssertTrue(message.contains(
            "fleetest remote exec M1Ultra -- api stop-device --name \"Pixel-01\" --device-machine local"),
            "project/profile 未指定なら足さない: \(message)")
        XCTAssertFalse(message.contains("--project"))
        XCTAssertFalse(message.contains("--profile"))
    }

    /// **G13**: 旧文言「pass --device-machine to say which one」は、この機械では実行できない
    /// 機械名を渡すよう誘導していた。新しい文言は「local でこの Mac」と「他機は remote exec」の
    /// 両方を言う
    func testAmbiguousMachineMessageOffersLocalAndRemoteExecChoices() {
        let message = ApiDeviceOperation.ambiguousMachineMessage(
            subcommand: "start-device", name: "iPhone-01", hosts: ["local", "M1Max", "M1Ultra"],
            project: nil, profile: nil, rosterLabel: "all run profiles of project \"default\"")
        XCTAssertTrue(message.contains("--device-machine local to operate on this Mac"),
                      "手元で完結する選択肢を言う: \(message)")
        XCTAssertTrue(message.contains("fleetest remote exec <machine> -- api start-device"),
                      "他機はその機械で操作する形を言う: \(message)")
        XCTAssertFalse(message.contains("pass --device-machine to say which one"),
                       "この機械では実行できない機械名を渡すよう誘導する旧文言を残さない: \(message)")
    }

    // MARK: - allRunProfilesLabel(純粋関数。M17: profile: 無指定の見出しにプロジェクト名を入れる)

    /// project: 無指定でも既定の1プロジェクトしか読まないため、見出しにその名前を入れる
    /// (fleetest-mcp 側の DeviceInventory.allRunProfilesLabel と同じ理由・同じ形)
    func testAllRunProfilesLabelNamesTheProject() {
        XCTAssertEqual(ApiDeviceOperation.allRunProfilesLabel(projectName: "default"),
                       "all run profiles of project \"default\"")
    }
}
