import FTServices
import FTTestSupport
import Foundation
import XCTest
@testable import fleetest

/// 控えの読み取りと孤児の選別。削除の実行は差し替え口(クロージャ)で受けて記録する = 実行基盤には触れない。
final class ServicesReaperTests: XCTestCase {

    private var root: URL!
    private var stateDir: URL!
    private var home: String!
    private let prefix = "fleetest-0123456789ab"
    private let deadPid: Int32 = 4_000_000
    private let livePid: Int32 = 4_000_001

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("services-reaper-\(UUID().uuidString)")
        stateDir = root.appendingPathComponent(".fleetest")
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(at: ServicesLeaseFile.directory(stateDir: stateDir), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func lease(pid: Int32, schema: Int = 2, kind: ServicesLease.Kind = .run) -> ServicesLease {
        ServicesLease(
            schemaVersion: schema, pid: pid, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "docker",
            endpoint: "/sock", prefix: prefix, generation: "g", workspace: "/ws", project: "p", profile: "r",
            containers: ["\(prefix)-db": "c1"], networks: [prefix: "n1"], phase: .running)
    }

    @discardableResult
    private func place(_ lease: ServicesLease, named name: String? = nil) throws -> URL {
        let url = ServicesLeaseFile.directory(stateDir: stateDir)
            .appendingPathComponent(name ?? ServicesLeaseFile.fileName(pid: lease.pid, prefix: lease.prefix))
        try ServicesLeaseStore.write(lease, to: url)
        return url
    }

    private func makePrivate(pid: Int32) throws -> String {
        let dir = ServicesSecretsLayoutProbe.privateDirectory(home: home, pid: pid)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/db.env", atomically: true, encoding: .utf8)
        return dir
    }

    private func isAlive(_ pid: Int32, _ startedAt: String) -> Bool { pid == livePid }

    func testDeadOwnersLeaseIsRemovedByItsRecordedIDsAndPrivateDirectoryGoes() throws {
        let url = try place(lease(pid: deadPid))
        let privateDir = try makePrivate(pid: deadPid)
        let removed = LockedBox<[ServicesLease]>([])
        let result = ServicesReaper.reap(stateDir: stateDir, home: home, isAlive: isAlive,
                                         remover: { lease in removed.mutate { $0.append(lease) }; return nil },
                                         log: { _ in })
        XCTAssertEqual(result.reaped, 1)
        XCTAssertTrue(result.unreadable.isEmpty)
        XCTAssertEqual(removed.value.count, 1)
        XCTAssertEqual(removed.value.first?.containers, ["\(prefix)-db": "c1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateDir))
    }

    func testLiveOwnersLeaseIsLeftAlone() throws {
        let url = try place(lease(pid: livePid))
        let removed = LockedBox<Int>(0)
        let result = ServicesReaper.reap(stateDir: stateDir, home: home, isAlive: isAlive,
                                         remover: { _ in removed.mutate { $0 += 1 }; return nil }, log: { _ in })
        XCTAssertEqual(result.reaped, 0)
        XCTAssertEqual(removed.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnreadableLeasesAreReportedAndNeverRemoved() throws {
        let dir = ServicesLeaseFile.directory(stateDir: stateDir)
        let garbage = dir.appendingPathComponent(ServicesLeaseFile.fileName(pid: deadPid, prefix: prefix))
        try "{not json".write(to: garbage, atomically: true, encoding: .utf8)
        let otherSchema = try place(lease(pid: 4_000_002, schema: 99))
        // ファイル名の pid と中身が食い違う
        let mismatched = try place(lease(pid: 4_000_003), named: ServicesLeaseFile.fileName(pid: 4_000_004, prefix: prefix))
        let removed = LockedBox<Int>(0)
        let logs = LockedBox<[String]>([])
        let result = ServicesReaper.reap(stateDir: stateDir, home: home, isAlive: isAlive,
                                         remover: { _ in removed.mutate { $0 += 1 }; return nil },
                                         log: { line in logs.mutate { $0.append(line) } })
        XCTAssertEqual(Set(result.unreadable.map(\.lastPathComponent)),
                       Set([garbage, otherSchema, mismatched].map(\.lastPathComponent)))
        XCTAssertEqual(result.reaped, 0)
        XCTAssertEqual(removed.value, 0)
        for url in [garbage, otherSchema, mismatched] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(logs.value.filter { $0.contains("unreadable lease") }.count, 3)
    }

    func testFilesInTheOldHookLeaseFormAreNotOurs() throws {
        let old = ServicesLeaseFile.directory(stateDir: stateDir).appendingPathComponent("\(deadPid).json")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        let result = ServicesReaper.reap(stateDir: stateDir, home: home, isAlive: isAlive,
                                         remover: { _ in nil }, log: { _ in })
        XCTAssertEqual(result.reaped, 0)
        XCTAssertTrue(result.unreadable.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testFailedRemovalKeepsTheLeaseWithOnlyWhatRemains() throws {
        let url = try place(lease(pid: deadPid))
        let privateDir = try makePrivate(pid: deadPid)
        var leftover = lease(pid: deadPid)
        leftover.containers = [:]
        let result = ServicesReaper.reap(stateDir: stateDir, home: home, isAlive: isAlive,
                                         remover: { _ in leftover }, log: { _ in })
        XCTAssertEqual(result.reaped, 0)
        XCTAssertEqual(result.kept.map(\.lastPathComponent), [url.lastPathComponent])
        let reread = ServicesLeaseStore.entries(stateDir: stateDir, prefix: prefix).first?.lease
        XCTAssertEqual(reread?.containers, [:])
        XCTAssertEqual(reread?.networks, [prefix: "n1"])
        // 資源が残る間は親専用の領域も残す(次の回収が使う)
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateDir))
    }

    func testEntriesFilterByPrefix() throws {
        try place(lease(pid: deadPid))
        var other = lease(pid: deadPid)
        other.prefix = "fleetest-ffffffffffff"
        try place(other)
        XCTAssertEqual(ServicesLeaseStore.entries(stateDir: stateDir).count, 2)
        XCTAssertEqual(ServicesLeaseStore.entries(stateDir: stateDir, prefix: prefix).count, 1)
    }

    /// 削除の失敗の文言が「無い」を表さない(Apple)ときの実在確認。一覧に無いときだけ消えたと言う。
    func testAbsenceIsConfirmedOnlyByAListingThatLacksTheResource() {
        let full = String(repeating: "0123456789ab", count: 5) + "0123"
        let docker = [(id: "0123456789ab", name: "fleetest-x-web"), (id: "fedcba987654", name: "fleetest-x-relay")]
        XCTAssertFalse(ServicesTeardown.absenceConfirmed(name: "fleetest-x-web", reference: full, listing: docker))
        // 中継は名前の代わりに ID を持つ: 短縮 ID の前方一致で「ある」
        XCTAssertFalse(ServicesTeardown.absenceConfirmed(name: "\u{0}relay", reference: "fedcba987654" + full.dropFirst(12), listing: docker))
        XCTAssertTrue(ServicesTeardown.absenceConfirmed(name: "fleetest-x-db", reference: String(repeating: "a", count: 64), listing: docker))
        // Apple は id == name。名前の前方一致では「ある」と言わない(fleetest-x-we と fleetest-x-web)
        let apple = [(id: "fleetest-x-we", name: "fleetest-x-we")]
        XCTAssertTrue(ServicesTeardown.absenceConfirmed(name: "fleetest-x-web", reference: "fleetest-x-web", listing: apple))
        XCTAssertFalse(ServicesTeardown.absenceConfirmed(name: "fleetest-x-we", reference: "fleetest-x-we", listing: apple))
        // 一覧が取れなければ「ある」
        XCTAssertFalse(ServicesTeardown.absenceConfirmed(name: "n", reference: "n", listing: nil))
    }

    func testGoneJudgementAndRemainingResources() {
        XCTAssertTrue(ServicesTeardown.isGone("Error: No such container: abc"))
        XCTAssertTrue(ServicesTeardown.isGone("network x not found"))
        XCTAssertFalse(ServicesTeardown.isGone("network has active endpoints"))
        var l = lease(pid: deadPid)
        XCTAssertTrue(l.hasResources)
        l.containers = [:]
        l.networks = [:]
        XCTAssertFalse(l.hasResources)
        l.relay = "r"
        XCTAssertTrue(l.hasResources)
    }

    func testTeardownBudgetUsesTheLongestDeclaredGrace() {
        var l = lease(pid: 1)
        XCTAssertEqual(ServicesTeardown.teardownBudgetSeconds(lease: l), 40, "default grace 10 + stop overhead 30")
        l.stopGraceSeconds = ["\(prefix)-db": 25, "\(prefix)-api": 5]
        XCTAssertEqual(ServicesTeardown.teardownBudgetSeconds(lease: l), 55)
    }
}

/// 親専用の領域のパスをテストでも同じ規則で作る(production の定数は参照せずリテラルで書く)。
private enum ServicesSecretsLayoutProbe {
    static func privateDirectory(home: String, pid: Int32) -> String { home + "/.config/fleetest/private/\(pid)" }
}
