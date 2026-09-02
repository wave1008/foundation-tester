// MachineInventory(実行プロファイル未選択のときの監視対象)の単体テスト。
// 実害の再現: マシンプロファイルが2つある案件で「(プロファイルなし)」を選ぶと1台も出なかった
// (台帳を1つに決められず「今動いている台」だけに縮退していた)。

import XCTest
@testable import FTCore

final class MachineInventoryTests: XCTestCase {

    private func profile(machine: String? = nil,
                         ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> MachineProfile {
        MachineProfile(machine: machine,
                       ios: MachineDeviceList(devices: ios),
                       android: MachineDeviceList(devices: android))
    }

    private func names(_ entries: [DeviceMachineGrouping.CatalogEntry]) -> [String] {
        entries.map { "\($0.platform):\(DeviceMachineGrouping.display($0.machine))/\($0.name)" }
    }

    func testKeepsLocalDevicesEvenWithAnEmptyRegistry() {
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [DeviceSpec(name: "A")], android: [DeviceSpec(name: "B")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/A", "android:local/B"])
    }

    func testKeepsOnlyMachinesInTheRegistry() {
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [
                DeviceSpec(name: "here"),
                DeviceSpec(name: "runner", machine: "M1Max"),
                // 登録簿に無い = fan-out が張られない = 状態が永久に unknown。出さない
                DeviceSpec(name: "ghost", machine: "RetiredMac"),
            ])],
            registry: ["M1Max", "M1Ultra"])
        XCTAssertEqual(names(entries), ["ios:local/here", "ios:M1Max/runner"])
    }

    func testMergesEveryMachineProfileAndDropsDuplicates() {
        // 手元の台は両方の台帳に居るのが普通(構成の使い分け)。重複はエラーではなく1件に畳む
        let onlyLocal = profile(ios: [DeviceSpec(name: "A"), DeviceSpec(name: "B")])
        let withRunners = profile(ios: [
            DeviceSpec(name: "A"),
            DeviceSpec(name: "C"),
            DeviceSpec(name: "A", machine: "M1Max"),  // 同名でもマシンが違えば別の台
        ])
        let entries = MachineInventory.observableEntries(
            profiles: [onlyLocal, withRunners], registry: ["M1Max"])
        XCTAssertEqual(names(entries), ["ios:local/A", "ios:local/B", "ios:local/C", "ios:M1Max/A"])
    }

    func testSamePlatformIsRequiredForADuplicate() {
        // プラットフォームが違えば同名でも別の台(iOS の "Pixel 9" という命名は普通ではないが、
        // 鍵から platform を落とすと片方が消えるので固定する)
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [DeviceSpec(name: "X")], android: [DeviceSpec(name: "X")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/X", "android:local/X"])
    }

    func testProfileDefaultMachineIsAppliedBeforeFiltering() {
        // 台帳ごと "machine" を持つ形(全台がそのマシンに居る)。デバイス側に machine が無くても
        // 実効マシンで判定する
        let entries = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Ultra", ios: [DeviceSpec(name: "A")])],
            registry: ["M1Ultra"])
        XCTAssertEqual(names(entries), ["ios:M1Ultra/A"])

        let dropped = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Ultra", ios: [DeviceSpec(name: "A")])],
            registry: [])
        XCTAssertTrue(dropped.isEmpty, "登録簿に無いマシンの台帳は丸ごと落ちる")
    }

    func testExplicitLocalBeatsTheProfileDefault() {
        // デバイス側の "local" は「手元」の明示指定で、台帳既定より強い
        // (DeviceMachineGrouping.effectiveMachine の規律をここでも守る)
        let entries = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Ultra", ios: [DeviceSpec(name: "A", machine: "local")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/A"])
    }

    // MARK: - identity の食い違い
    //
    // 実害 2026-09-03: ランナー機の視点で書かれた台帳(`machine: "local"` のまま)が手元の台帳と
    // 同居し、手元に実在しない udid の台が (ios, local, 名前) を先に埋めた。負けた本物の
    // シミュレータは「未登録の起動中デバイス」として合成され、id 衝突で毎周期落ちていた
    // (= 起動中の台が監視から消える)。

    private func source(_ name: String, machine: String? = nil,
                        ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> MachineInventory.Source {
        MachineInventory.Source(name: name, profile: profile(machine: machine, ios: ios, android: android))
    }

    func testDisagreeingIdentitiesAreReportedWithBothLedgersNamed() {
        let merged = MachineInventory.merge(
            sources: [
                source("M1Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("M2Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "BBB")]),
            ],
            registry: [])
        XCTAssertEqual(names(merged.entries), ["ios:local/sim-01"], "畳み込みは従来どおり先頭を採る")
        XCTAssertEqual(merged.conflicts.count, 1)
        let message = merged.conflicts.first?.message ?? ""
        XCTAssertTrue(message.contains("M1Ultra.json"), message)
        XCTAssertTrue(message.contains("M2Ultra.json"), message)
        XCTAssertTrue(message.contains("udid AAA"), message)
        XCTAssertTrue(message.contains("udid BBB"), message)
        XCTAssertTrue(message.contains("ios:local/sim-01"), message)
    }

    func testTheSameDeviceInTwoLedgersIsNotAConflict() {
        // 手元の台を両方の台帳に書くのは普通。**同じ実体なら黙る**
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", os: "27.0", udid: "AAA")]),
            ],
            registry: [])
        XCTAssertEqual(merged.conflicts, [])
    }

    func testALedgerThatNamesNoIdentityIsNotAConflict() {
        // 片方が名前だけ(または simulator/os だけ)なのは同じ台の粗い記述 —— 誤検知を出さない
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", simulator: "iPhone 17 Pro", os: "27.0")]),
            ],
            registry: [])
        XCTAssertEqual(merged.conflicts, [])
    }

    func testAndroidLedgersAreComparedByAVDAndSerial() {
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", android: [DeviceSpec(name: "emu-01", avd: "Pixel_9-01"),
                                           DeviceSpec(name: "phone", serial: "S1")]),
                source("b.json", android: [DeviceSpec(name: "emu-01", avd: "Pixel_9-02"),
                                           DeviceSpec(name: "phone", serial: "S2")]),
            ],
            registry: [])
        XCTAssertEqual(merged.conflicts.map(\.name).sorted(), ["emu-01", "phone"])
        XCTAssertTrue(merged.conflicts.contains { $0.message.contains("avd Pixel_9-02") },
                      "\(merged.conflicts.map(\.message))")
        XCTAssertTrue(merged.conflicts.contains { $0.message.contains("serial S2") },
                      "\(merged.conflicts.map(\.message))")
    }

    func testADeviceOnAnotherMachineIsNotComparedWithTheLocalOneOfTheSameName() {
        // (machine, name) が鍵 —— 各機が同じ命名規則で作るので、同名・別 udid は通常の姿
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", machine: "M1Max", udid: "BBB")]),
            ],
            registry: ["M1Max"])
        XCTAssertEqual(names(merged.entries), ["ios:local/sim-01", "ios:M1Max/sim-01"])
        XCTAssertEqual(merged.conflicts, [])
    }

    func testLoadAllNamedCarriesTheFileNameForTheWarning() throws {
        let project = try projectWithMachines([
            "M1Ultra": #"{"ios":{"devices":[{"name":"sim-01","udid":"AAA"}]}}"#,
            "M2Ultra": #"{"ios":{"devices":[{"name":"sim-01","udid":"BBB"}]}}"#,
        ])
        let sources = MachineInventory.loadAllNamed(project: project) { _ in
            XCTFail("読める台帳で警告は出ない")
        }
        XCTAssertEqual(sources.map(\.name), ["M1Ultra.json", "M2Ultra.json"])
        let merged = MachineInventory.merge(sources: sources, registry: [])
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertTrue(merged.conflicts.first?.message.contains("M2Ultra.json") == true,
                      "\(merged.conflicts)")
    }

    /// **リポジトリの台帳全数に当てて誤検知0**(新しい検知の規律。CLAUDE.md §検知を足すとき)。
    /// 同時に**この型の再発を落とすゲート**でもある —— 食い違ったまま気付かないと、
    /// 「(プロファイルなし)」の監視から実在する台が黙って消える
    func testTheCommittedLedgersOfThisRepositoryDoNotDisagree() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let projectsDir = repoRoot.appendingPathComponent("TestProjects")
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path)) ?? []
        // 0件なら検証していないのと同じ(常に緑の空テストにしない)
        XCTAssertFalse(projects.isEmpty, "TestProjects/ が読めない: \(projectsDir.path)")
        for name in projects.sorted() {
            let project = TestProject(name: name, rootURL: projectsDir.appendingPathComponent(name))
            guard FileManager.default.fileExists(atPath: project.machinesDir.path) else { continue }
            let sources = MachineInventory.loadAllNamed(project: project) { _ in }
            // 登録簿は案件ごとに違うので、**全マシンを観測できる**前提で当てる(いちばん広い集合)
            let registry = sources.flatMap { source in
                DeviceMachineGrouping.entries(machine: source.profile).compactMap(\.machine)
            }
            let conflicts = MachineInventory.merge(sources: sources, registry: registry).conflicts
            XCTAssertEqual(conflicts, [], "\(name): \(conflicts.map(\.message).joined(separator: " / "))")
        }
    }

    // MARK: - loadAll / mergedProfile
    //
    // 「(プロファイルなし)」で**タイルからブリッジを起動できる**ことを支える2つ
    // (ApiDeviceOperation.run が台帳を1つに決められず落ちていた。実害 2026-08-29)。

    private func projectWithMachines(_ files: [String: String]) throws -> TestProject {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleetest-machine-inventory-\(UUID().uuidString)")
        let machines = root.appendingPathComponent("profiles/machines")
        try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, body) in files {
            try body.write(to: machines.appendingPathComponent("\(name).json"),
                           atomically: true, encoding: .utf8)
        }
        return TestProject(name: "p", rootURL: root)
    }

    func testLoadAllReadsEveryLedgerInFileNameOrder() throws {
        // **並びが結果を決める**(observableEntries の重複解決は入力順で先頭を採る)ので固定する
        let project = try projectWithMachines([
            "zzz": #"{"ios":{"devices":[{"name":"Z"}]}}"#,
            "aaa": #"{"ios":{"devices":[{"name":"A"}]}}"#,
        ])
        let loaded = MachineInventory.loadAll(project: project) { _ in
            XCTFail("読める台帳で警告は出ない")
        }
        XCTAssertEqual(loaded.map { $0.ios?.devices?.first?.name }, ["A", "Z"])
    }

    func testABrokenLedgerIsSkippedWithAWarningInsteadOfStoppingEverything() throws {
        // 1枚壊れていても残りは見せる —— ここは「見えるものを見せる」経路
        let project = try projectWithMachines([
            "broken": "{ not json",
            "good": #"{"ios":{"devices":[{"name":"A"}]}}"#,
        ])
        var warnings: [String] = []
        let loaded = MachineInventory.loadAll(project: project) { warnings.append($0) }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.ios?.devices?.first?.name, "A")
        // 添字で読まない —— 変異で0件になったときにクラッシュすると「検出」ではなく
        // 「実行できなかった」に化けて、変異チェックの判定が濁る
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("broken") == true, "\(warnings)")
    }

    func testMergedProfileSplitsByPlatformAndKeepsTheMachineOnEachDevice() {
        let entries = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Max", ios: [DeviceSpec(name: "A")],
                               android: [DeviceSpec(name: "B")]),
                       profile(ios: [DeviceSpec(name: "C")])],
            registry: ["M1Max"])
        let merged = MachineInventory.mergedProfile(entries)
        // 台帳既定は持たない —— **マシンは各デバイスに焼き込む**。既定を残すと、
        // 手元の台まで M1Max の台と読まれて別の機械へ回る
        XCTAssertNil(merged.machine)
        XCTAssertEqual(merged.ios?.devices?.map { "\($0.name)@\($0.machine ?? "-")" }, ["A@M1Max", "C@-"])
        XCTAssertEqual(merged.android?.devices?.map { "\($0.name)@\($0.machine ?? "-")" }, ["B@M1Max"])
    }
}
