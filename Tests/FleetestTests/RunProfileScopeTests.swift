// 実行プロファイルによるマシンプロファイルの絞り込み。
// `api monitor --profile` と `devices up/down --profile` が共有する経路で、ここが誤ると
// 「意図しないデバイスを起動・停止する」「監視対象が欠ける」という形で実機側に影響が出る。
// 実機なしで固められる部分なので単体テストで押さえる。

import XCTest
import FTCore
@testable import fleetest

final class RunProfileScopeTests: XCTestCase {

    private var tempDir: URL!
    private var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetestTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        try FileManager.default.createDirectory(at: project.runsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - fixtures

    private func writeRunProfile(_ name: String, deviceNames: [String]?) throws {
        var doc: [String: Any] = ["machine": "M2 Ultra"]
        if let deviceNames {
            doc["devices"] = deviceNames.map { ["name": $0] }
        }
        let data = try JSONSerialization.data(withJSONObject: doc)
        try data.write(to: project.runsDir.appendingPathComponent("\(name).json"))
    }

    private func machineProfile(ios: [String], android: [String]) -> MachineProfile {
        MachineProfile(
            ios: ios.isEmpty ? nil : MachineDeviceList(devices: ios.map { DeviceSpec(name: $0) }),
            android: android.isEmpty ? nil : MachineDeviceList(devices: android.map { DeviceSpec(name: $0) }))
    }

    private func filtered(runProfile: String, machine: MachineProfile,
                          warnings: inout [String]) throws -> MachineProfile {
        var collected: [String] = []
        defer { warnings = collected }
        return try RunProfileScope.filteredMachineProfile(
            project: project, machineName: "M2 Ultra", machineProfile: machine,
            runProfileName: runProfile, warn: { collected.append($0) })
    }

    // MARK: - 正常系

    func testKeepsOnlyReferencedDevicesAcrossPlatforms() throws {
        try writeRunProfile("mixed", deviceNames: ["シミュ1", "エミュ2"])
        var warnings: [String] = []
        let result = try filtered(
            runProfile: "mixed",
            machine: machineProfile(ios: ["シミュ1", "シミュ2"], android: ["エミュ1", "エミュ2"]),
            warnings: &warnings)

        XCTAssertEqual(result.ios?.devices?.map(\.name), ["シミュ1"])
        XCTAssertEqual(result.android?.devices?.map(\.name), ["エミュ2"])
        XCTAssertTrue(warnings.isEmpty)
    }

    func testPlatformWithNoSurvivingDeviceBecomesNil() throws {
        // 片 OS だけを指す実行プロファイルで、もう片方が空リストではなく nil になること
        // (空リストだと「0台のプラットフォームがある」として扱われうる)
        try writeRunProfile("ios-only", deviceNames: ["シミュ1"])
        var warnings: [String] = []
        let result = try filtered(
            runProfile: "ios-only",
            machine: machineProfile(ios: ["シミュ1"], android: ["エミュ1"]),
            warnings: &warnings)

        XCTAssertEqual(result.ios?.devices?.count, 1)
        XCTAssertNil(result.android)
    }

    func testPreservesMachineProfileOrderNotRunProfileOrder() throws {
        // 起動順はマシンプロファイルの並びで決まる。実行プロファイルの記述順で並べ替えない
        try writeRunProfile("reordered", deviceNames: ["シミュ3", "シミュ1"])
        var warnings: [String] = []
        let result = try filtered(
            runProfile: "reordered",
            machine: machineProfile(ios: ["シミュ1", "シミュ2", "シミュ3"], android: []),
            warnings: &warnings)

        XCTAssertEqual(result.ios?.devices?.map(\.name), ["シミュ1", "シミュ3"])
    }

    // MARK: - 警告(処理は継続)

    func testWarnsButContinuesWhenSomeReferencedDevicesAreMissing() throws {
        // マシンごとにデバイス構成が違うのは想定内。1台でも残れば続行する
        try writeRunProfile("partial", deviceNames: ["シミュ1", "居ない機"])
        var warnings: [String] = []
        let result = try filtered(
            runProfile: "partial",
            machine: machineProfile(ios: ["シミュ1"], android: []),
            warnings: &warnings)

        XCTAssertEqual(result.ios?.devices?.map(\.name), ["シミュ1"])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("居ない機"), "欠けたデバイス名を警告に含めること: \(warnings[0])")
    }

    // MARK: - 異常系

    func testThrowsWhenRunProfileFileIsMissing() throws {
        var warnings: [String] = []
        XCTAssertThrowsError(try filtered(
            runProfile: "存在しない", machine: machineProfile(ios: ["シミュ1"], android: []),
            warnings: &warnings))
    }

    func testThrowsWhenRunProfileHasNoDevices() throws {
        // devices を持たない実行プロファイルを「全台」と解釈しない(誤って全台起動しないため)
        try writeRunProfile("nodevices", deviceNames: nil)
        var warnings: [String] = []
        XCTAssertThrowsError(try filtered(
            runProfile: "nodevices", machine: machineProfile(ios: ["シミュ1"], android: []),
            warnings: &warnings))
    }

    func testThrowsWhenRunProfileHasEmptyDeviceList() throws {
        try writeRunProfile("empty", deviceNames: [])
        var warnings: [String] = []
        XCTAssertThrowsError(try filtered(
            runProfile: "empty", machine: machineProfile(ios: ["シミュ1"], android: []),
            warnings: &warnings))
    }

    func testThrowsWhenNoReferencedDeviceExistsOnThisMachine() throws {
        try writeRunProfile("foreign", deviceNames: ["別マシンの機1", "別マシンの機2"])
        var warnings: [String] = []
        XCTAssertThrowsError(try filtered(
            runProfile: "foreign", machine: machineProfile(ios: ["シミュ1"], android: ["エミュ1"]),
            warnings: &warnings))
    }

    func testThrowsWhenRunProfileIsNotDecodable() throws {
        try Data("{ これは JSON ではない".utf8)
            .write(to: project.runsDir.appendingPathComponent("broken.json"))
        var warnings: [String] = []
        XCTAssertThrowsError(try filtered(
            runProfile: "broken", machine: machineProfile(ios: ["シミュ1"], android: []),
            warnings: &warnings))
    }
}

// MARK: - デバイス単位の host(混在プロファイル)

extension RunProfileScopeTests {

    /// 参照は (host, name)。**名前だけで絞ると選んでいない台まで混ざる** ——
    /// モニターに未選択のタイルが並び、devices up が別の機械のぶんまで起こそうとする
    /// (2026-08-17 の実害)
    func testKeepsOnlyTheReferencedHostsDevice() throws {
        let doc: [String: Any] = [
            "machine": "M2 Ultra",
            "devices": [["host": "local", "name": "iPhone-01"]],
        ]
        try JSONSerialization.data(withJSONObject: doc)
            .write(to: project.runsDir.appendingPathComponent("scoped.json"))

        let machine = MachineProfile(ios: MachineDeviceList(devices: [
            DeviceSpec(name: "iPhone-01", host: "local", udid: "LOCAL"),
            DeviceSpec(name: "iPhone-01", host: "M1Ultra", udid: "REMOTE"),
        ]))
        var warnings: [String] = []
        let result = try filtered(runProfile: "scoped", machine: machine, warnings: &warnings)
        XCTAssertEqual(result.ios?.devices?.map { $0.udid }, ["LOCAL"])
        XCTAssertEqual(warnings, [])
    }

    /// host を書いていない参照が複数ホストに当たったら**触らない**(どちらの機械か決まらない台を
    /// 起動・監視しない)。run 側は同じ状況で中止する
    func testAmbiguousReferenceIsSkippedWithAWarning() throws {
        let doc: [String: Any] = [
            "machine": "M2 Ultra",
            "devices": [["name": "iPhone-01"], ["host": "M1Ultra", "name": "iPhone-02"]],
        ]
        try JSONSerialization.data(withJSONObject: doc)
            .write(to: project.runsDir.appendingPathComponent("ambiguous.json"))

        let machine = MachineProfile(ios: MachineDeviceList(devices: [
            DeviceSpec(name: "iPhone-01", host: "local"),
            DeviceSpec(name: "iPhone-01", host: "M1Ultra"),
            DeviceSpec(name: "iPhone-02", host: "M1Ultra"),
        ]))
        var warnings: [String] = []
        let result = try filtered(runProfile: "ambiguous", machine: machine, warnings: &warnings)
        XCTAssertEqual(result.ios?.devices?.map { $0.name }, ["iPhone-02"])
        XCTAssertTrue(warnings.contains { $0.contains("ambiguous") }, "\(warnings)")
    }

    /// 実効ホストは spec.host へ書き戻る(モニターがタイルにホスト名を出せる)
    func testEffectiveHostIsStampedOntoTheReturnedSpecs() throws {
        let doc: [String: Any] = [
            "machine": "M2 Ultra", "devices": [["host": "M1Max", "name": "iPhone-09"]],
        ]
        try JSONSerialization.data(withJSONObject: doc)
            .write(to: project.runsDir.appendingPathComponent("stamped.json"))

        // デバイス側は host を書かず、プロファイル直下の既定から継ぐ形
        let machine = MachineProfile(host: "M1Max",
                                     ios: MachineDeviceList(devices: [DeviceSpec(name: "iPhone-09")]))
        var warnings: [String] = []
        let result = try filtered(runProfile: "stamped", machine: machine, warnings: &warnings)
        XCTAssertEqual(result.ios?.devices?.map { $0.host }, ["M1Max"])
    }
}
