// マシン別サブ実行のデバイス絞り込み(`ResolvedProfile.filteringDevices`)。
//
// 実害(2026-08-17 の実走): 1つの実行プロファイルが3台の機械にまたがるとき、サブ実行には
// `--device <名前…>` だけを渡していた。**一意なのは name 単体ではなく (host, name)** で、
// フリートの各機は同じ命名規則でシミュレータを作る = 同名は例外ではなく通常なので、
// 手元のサブ実行が3機ぶんの "iPhone 17 Pro(iOS 27.0)-01" を全部拾い、
// **4台のはずが8台**になった(手元に同名の台があれば、それを別の機械の台として操作する)。
//
// さらにリモートへの中継(`RemoteRunArgs.build`)は `--device` を**1つも渡していなかった**ので、
// 向こうは12台すべてを自分のものとして解決しようとしていた。

import Foundation
import XCTest

@testable import FTCore

final class ResolvedProfileDeviceScopeTests: XCTestCase {

    private func device(_ name: String, host: String?, platform: String = "ios") -> ResolvedDevice {
        var spec = DeviceSpec(name: name, os: "27.0")
        spec.machine = host
        return ResolvedDevice(platform: platform, spec: spec)
    }

    /// 同名の台が3機にある + 名前の違う Android、という実物と同じ形
    private func profile() -> ResolvedProfile {
        make(devices: [
            device("iPhone-01", host: nil), device("iPhone-02", host: nil),
            device("iPhone-01", host: "M1Max"), device("iPhone-02", host: "M1Max"),
            device("iPhone-01", host: "M1Ultra"), device("iPhone-02", host: "M1Ultra"),
            device("Pixel-local-01", host: nil, platform: "android"),
            device("Pixel-M1Max-01", host: "M1Max", platform: "android"),
        ])
    }

    /// memberwise init は internal なので `@testable import FTCore` で触る
    /// (BuildAndroidWorkersPartialFailureTests と同じ手段)
    private func make(devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "local+remote", machineName: "local+remote", appName: "app", apps: [:],
            devices: devices, fm: FMConfig(),
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosFastInput: false, containerInference: true, enableAnimations: false,
            homeOnStart: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    private func hosts(_ profile: ResolvedProfile) -> [String] {
        profile.devices.map { "\(MachineDispatch.normalize($0.spec.machine) ?? "local")/\($0.name)" }
    }

    func testLocalSubRunDoesNotPickUpTheOtherMachinesSameNamedDevices() {
        let scoped = profile().filteringDevices(
            names: ["iPhone-01", "iPhone-02", "Pixel-local-01"], deviceMachine: "local")
        XCTAssertEqual(hosts(scoped), ["local/iPhone-01", "local/iPhone-02", "local/Pixel-local-01"],
                       "名前だけで絞ると3機ぶんの同名を全部掴む(実走で 4台 → 8台になった形)")
    }

    func testRemoteSubRunKeepsOnlyThatMachinesDevices() {
        let scoped = profile().filteringDevices(
            names: ["iPhone-01", "iPhone-02", "Pixel-M1Max-01"], deviceMachine: "M1Max")
        XCTAssertEqual(hosts(scoped),
                       ["M1Max/iPhone-01", "M1Max/iPhone-02", "M1Max/Pixel-M1Max-01"])
    }

    func testHostAloneIsEnoughToScope() {
        // 名前を渡さなくてもホストだけで絞れる(中継が --device を落としても壊れない側に倒す)
        let scoped = profile().filteringDevices(names: [], deviceMachine: "M1Ultra")
        XCTAssertEqual(hosts(scoped), ["M1Ultra/iPhone-01", "M1Ultra/iPhone-02"])
    }

    func testNoHostGivenKeepsTheOldNameOnlyBehaviour() {
        // 単独の `--device`(利用者が手で打つ形)は従来どおり名前だけで絞る
        let scoped = profile().filteringDevices(names: ["Pixel-local-01"])
        XCTAssertEqual(hosts(scoped), ["local/Pixel-local-01"])
    }

    func testNothingGivenKeepsEveryDevice() {
        XCTAssertEqual(profile().filteringDevices(names: []).devices.count, 8)
    }

    func testExplicitLocalOnADeviceCountsAsThisMachine() {
        let resolved = make(devices: [device("A", host: "local"), device("A", host: "M1Max")])
        let scoped = resolved.filteringDevices(names: ["A"], deviceMachine: "local")
        XCTAssertEqual(hosts(scoped), ["local/A"],
                       "\"local\" の明示は「手元」の意味(未指定と同じ扱いにする)")
    }
}
