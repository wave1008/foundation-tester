// MachineInventory(実行プロファイル未選択のときの監視対象)の単体テスト。
// 台帳 = 全実行プロファイルの devices。1つに決められないという理由で「今動いている台」だけに
// 縮退すると、未起動の台が1台も出ない(実害 2026-08-28)。

import XCTest
@testable import FTCore

final class MachineInventoryTests: XCTestCase {

    private func profile(ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> DeviceRoster {
        DeviceRoster(ios: DeviceRosterList(devices: ios),
                     android: DeviceRosterList(devices: android))
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

    func testMergesEveryRunProfileAndDropsDuplicates() {
        // 同じ台は複数の実行プロファイルに居るのが普通。重複はエラーではなく1件に畳む
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

    /// "local"・空文字は手元に畳む(登録簿に無くても残る)
    func testExplicitLocalAndEmptyMachineAreLocal() {
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [DeviceSpec(name: "A", machine: "local"),
                                     DeviceSpec(name: "B", machine: " ")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/A", "ios:local/B"])
    }

    // MARK: - identity の食い違い
    //
    // 実害 2026-09-03: ランナー機の視点で書かれた台帳(`machine: "local"` のまま)が手元の台帳と
    // 同居し、手元に実在しない udid の台が (ios, local, 名前) を先に埋めた。負けた本物の
    // シミュレータは「未登録の起動中デバイス」として合成され、id 衝突で毎周期落ちていた
    // (= 起動中の台が監視から消える)。

    private func source(_ name: String,
                        ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> MachineInventory.Source {
        MachineInventory.Source(name: name, profile: profile(ios: ios, android: android))
    }

    func testDisagreeingIdentitiesAreReportedWithBothLedgersNamed() {
        let merged = MachineInventory.merge(
            sources: [
                source("M1Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("M2Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "BBB")]),
            ],
            registry: [], existsLocally: nil)
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
            registry: [], existsLocally: nil)
        XCTAssertEqual(merged.conflicts, [])
    }

    func testALedgerThatNamesNoIdentityIsNotAConflict() {
        // 片方が名前だけ(または simulator/os だけ)なのは同じ台の粗い記述 —— 誤検知を出さない
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", simulator: "iPhone 17 Pro", os: "27.0")]),
            ],
            registry: [], existsLocally: nil)
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
            registry: [], existsLocally: nil)
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
            registry: ["M1Max"], existsLocally: nil)
        XCTAssertEqual(names(merged.entries), ["ios:local/sim-01", "ios:M1Max/sim-01"])
        XCTAssertEqual(merged.conflicts, [])
    }

    // MARK: - 実在で決める(手元の台だけ)
    //
    // 述語(existsLocally)は呼び手が起動時に1回だけ材料を採って畳んだもの
    // (ApiMonitorCommand.localPresencePredicate)。merge 自体は I/O を持たない。

    /// 実害の witness: 先頭の台帳が手元に実在しない udid を名乗り、後続が実在する台を名乗る
    func testTheLedgerWhoseDeviceExistsOnThisMachineWins() {
        let merged = MachineInventory.merge(
            sources: [
                source("M1Ultra.json", ios: [DeviceSpec(name: "sim-00", udid: "KEEP"),
                                             DeviceSpec(name: "sim-01", udid: "PHANTOM")]),
                source("M2Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "REAL")]),
            ],
            registry: [],
            existsLocally: { ["KEEP", "REAL"].contains($0.udid ?? "") })
        // 差し替えても並びは最初に現れた場所のまま
        XCTAssertEqual(names(merged.entries), ["ios:local/sim-00", "ios:local/sim-01"])
        XCTAssertEqual(merged.entries.map { $0.spec.udid }, ["KEEP", "REAL"])
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertEqual(merged.conflicts.first?.resolvedByLocalPresence, true)
        // **決着した行は警告ではなく事実の報告**として読めること(決着できなかった下の行と別物)
        XCTAssertEqual(
            merged.conflicts.first?.message,
            "run profiles disagree about ios:local/sim-01:"
            + " M2Ultra.json says udid REAL, M1Ultra.json says udid PHANTOM."
            + " Using M2Ultra.json — that device exists on this machine,"
            + " the one M1Ultra.json describes does not.")
    }

    func testTheFirstLedgerStillWinsWhenBothDevicesExist() {
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", udid: "BBB")]),
            ],
            registry: [], existsLocally: { _ in true })
        XCTAssertEqual(merged.entries.map { $0.spec.udid }, ["AAA"])
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertEqual(merged.conflicts.first?.resolvedByLocalPresence, false)
    }

    func testTheFirstLedgerStillWinsWhenNeitherDeviceExists() {
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", udid: "BBB")]),
            ],
            registry: [], existsLocally: { _ in false })
        XCTAssertEqual(merged.entries.map { $0.spec.udid }, ["AAA"])
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertEqual(merged.conflicts.first?.resolvedByLocalPresence, false)
    }

    func testWithoutThePredicateTheOutcomeAndTheWordingAreUnchanged() {
        let merged = MachineInventory.merge(
            sources: [
                source("M1Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "AAA")]),
                source("M2Ultra.json", ios: [DeviceSpec(name: "sim-01", udid: "BBB")]),
            ],
            registry: [], existsLocally: nil)
        XCTAssertEqual(merged.entries.map { $0.spec.udid }, ["AAA"])
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertEqual(merged.conflicts.first?.resolvedByLocalPresence, false)
        XCTAssertEqual(
            merged.conflicts.first?.message,
            "run profiles disagree about ios:local/sim-01:"
            + " M1Ultra.json says udid AAA, M2Ultra.json says udid BBB."
            + " Using M1Ultra.json — the device M2Ultra.json describes is not listed."
            + " Is one of them written from another machine's point of view"
            + " (\"machine\": \"local\" for a device that lives on a runner)?")
    }

    func testADeviceOnAnotherMachineIsNeverJudgedByLocalPresence() {
        // 他機の台の実体はこの機械からは見えない —— 述語に訊きもしない
        var asked: [String] = []
        let merged = MachineInventory.merge(
            sources: [
                source("a.json", ios: [DeviceSpec(name: "sim-01", machine: "M1Max", udid: "PHANTOM")]),
                source("b.json", ios: [DeviceSpec(name: "sim-01", machine: "M1Max", udid: "REAL")]),
            ],
            registry: ["M1Max"],
            existsLocally: { spec in
                asked.append(spec.udid ?? "")
                return spec.udid == "REAL"
            })
        XCTAssertEqual(merged.entries.map { $0.spec.udid }, ["PHANTOM"], "他機の台は先頭優先のまま")
        XCTAssertEqual(asked, [])
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertEqual(merged.conflicts.first?.resolvedByLocalPresence, false)
    }

    func testLoadAllNamedCarriesTheFileNameForTheWarning() throws {
        let project = try projectWithRuns([
            "M1Ultra": #"{"devices":[{"platform":"ios","name":"sim-01","udid":"AAA"}]}"#,
            "M2Ultra": #"{"devices":[{"platform":"ios","name":"sim-01","udid":"BBB","enabled":false}]}"#,
        ])
        let sources = MachineInventory.loadAllNamed(project: project) { _ in
            XCTFail("読める台帳で警告は出ない")
        }
        XCTAssertEqual(sources.map(\.name), ["runs/M1Ultra.json", "runs/M2Ultra.json"])
        let merged = MachineInventory.merge(sources: sources, registry: [], existsLocally: nil)
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
            guard FileManager.default.fileExists(atPath: project.runsDir.path) else { continue }
            let sources = MachineInventory.loadAllNamed(project: project) { _ in }
            // 登録簿は案件ごとに違うので、**全マシンを観測できる**前提で当てる(いちばん広い集合)
            let registry = sources.flatMap { source in
                DeviceMachineGrouping.entries(roster: source.profile).compactMap(\.machine)
            }
            let conflicts = MachineInventory.merge(
                sources: sources, registry: registry, existsLocally: nil).conflicts
            XCTAssertEqual(conflicts, [], "\(name): \(conflicts.map(\.message).joined(separator: " / "))")
        }
    }

    // MARK: - loadAll / mergedProfile
    //
    // 「(プロファイルなし)」で**タイルからブリッジを起動できる**ことを支える2つ
    // (ApiDeviceOperation.run が台帳を1つに決められず落ちていた。実害 2026-08-29)。

    private func projectWithRuns(_ files: [String: String]) throws -> TestProject {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleetest-machine-inventory-\(UUID().uuidString)")
        let project = TestProject(name: "p", rootURL: root)
        try FileManager.default.createDirectory(at: project.runsDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, body) in files {
            try body.write(to: project.runsDir.appendingPathComponent("\(name).json"),
                           atomically: true, encoding: .utf8)
        }
        return project
    }

    func testLoadAllReadsEveryLedgerInFileNameOrder() throws {
        // **並びが結果を決める**(observableEntries の重複解決は入力順で先頭を採る)ので固定する。
        // enabled: false の台も台帳に載る(プロファイルを選んでいないときの監視・起動の対象)
        let project = try projectWithRuns([
            "zzz": #"{"devices":[{"platform":"ios","name":"Z"}]}"#,
            "aaa": #"{"devices":[{"platform":"ios","machine":"M1","name":"A","enabled":false}]}"#,
        ])
        let loaded = MachineInventory.loadAll(project: project) { _ in
            XCTFail("読める台帳で警告は出ない")
        }
        XCTAssertEqual(loaded.map { $0.ios?.devices?.first?.name }, ["A", "Z"])
        XCTAssertEqual(loaded.map { $0.ios?.devices?.first?.machine }, ["M1", nil], "machine は正規化して焼き込む")
    }

    func testABrokenLedgerIsSkippedWithAWarningInsteadOfStoppingEverything() throws {
        // 1枚壊れていても残りは見せる —— ここは「見えるものを見せる」経路
        let project = try projectWithRuns([
            "broken": "{ not json",
            "good": #"{"devices":[{"platform":"ios","name":"A"}]}"#,
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
            profiles: [profile(ios: [DeviceSpec(name: "A", machine: "M1Max")],
                               android: [DeviceSpec(name: "B", machine: "M1Max")]),
                       profile(ios: [DeviceSpec(name: "C")])],
            registry: ["M1Max"])
        let merged = MachineInventory.mergedProfile(entries)
        // **マシンは各デバイスに焼き込む**
        XCTAssertEqual(merged.ios?.devices?.map { "\($0.name)@\($0.machine ?? "-")" }, ["A@M1Max", "C@-"])
        XCTAssertEqual(merged.android?.devices?.map { "\($0.name)@\($0.machine ?? "-")" }, ["B@M1Max"])
    }
}
