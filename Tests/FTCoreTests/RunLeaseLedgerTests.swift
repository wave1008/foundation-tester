// RunLeaseLedger(RunOrchestrator の run-lease / 録画 lease の記帳)の検証。
// 守るもの: ①外したキーをハートビートが書き戻さない ②持っていないキーのファイルを消さない
// (同じファイルを供給フェーズの lease が持っている)。

import XCTest
@testable import FTCore

final class RunLeaseLedgerTests: XCTestCase {

    /// write/remove の呼び出しを順に記録する(ledger はアクターなので、書き手はどのスレッドからでも呼ばれうる)
    private final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(op: String, key: String)] = []
        func append(_ op: String, _ key: String) {
            lock.lock(); entries.append((op, key)); lock.unlock()
        }
        var all: [(op: String, key: String)] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
        func ops(for key: String) -> [String] { all.filter { $0.key == key }.map(\.op) }
    }

    private func makeLedger(_ journal: Journal) -> RunLeaseLedger {
        RunLeaseLedger(write: { journal.append("write", $0) },
                       remove: { journal.append("remove", $0) })
    }

    func testHeartbeatRewritesOnlyHeldKeys() async {
        let journal = Journal()
        let ledger = makeLedger(journal)
        await ledger.acquire("emulator-5554")
        await ledger.acquire("emulator-5556")
        await ledger.release("emulator-5554")
        await ledger.heartbeat()
        XCTAssertEqual(journal.ops(for: "emulator-5554"), ["write", "remove"],
                       "外したキーをハートビートが書き戻した(担当を終えた台が run 中に見え続ける)")
        XCTAssertEqual(journal.ops(for: "emulator-5556"), ["write", "write"])
    }

    /// 持っていないキーは消さない —— 供給フェーズの lease(SupplyLeaseHolder)が同じファイルを
    /// 持っていることがあり、消すとそちらの次のハートビートまで穴が空いて書き戻される
    func testReleasingAKeyThatWasNeverAcquiredDoesNotTouchTheFile() async {
        let journal = Journal()
        let ledger = makeLedger(journal)
        let removed = await ledger.release("UDID-A")
        XCTAssertFalse(removed)
        XCTAssertTrue(journal.all.isEmpty, "持っていないキーのファイルを消した")
        // 2度目の release も同じ(二重に外しても1回しか消さない)
        await ledger.acquire("UDID-A")
        let first = await ledger.release("UDID-A")
        let second = await ledger.release("UDID-A")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(journal.ops(for: "UDID-A"), ["write", "remove"])
    }

    func testReleaseAllRemovesEveryHeldKeyOnce() async {
        let journal = Journal()
        let ledger = makeLedger(journal)
        await ledger.acquire("a")
        await ledger.acquire("b")
        await ledger.release("a")
        await ledger.releaseAll()
        await ledger.heartbeat()
        XCTAssertEqual(journal.ops(for: "a"), ["write", "remove"])
        XCTAssertEqual(journal.ops(for: "b"), ["write", "remove"])
        let stillHeld = await ledger.holds("b")
        XCTAssertFalse(stillHeld)
    }

    /// ハートビートと release を並行に撃っても、**外したキーの最後の操作は必ず remove**
    /// (書き込みがアクターの外にあると、一覧を取った直後の release の後に書き戻せる)
    func testConcurrentHeartbeatNeverResurrectsAReleasedKey() async {
        let journal = Journal()
        let ledger = makeLedger(journal)
        let keys = (0..<64).map { "emulator-\(5554 + $0 * 2)" }
        for key in keys { await ledger.acquire(key) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<20 { await ledger.heartbeat() } }
            }
            for key in keys {
                group.addTask { _ = await ledger.release(key) }
            }
        }
        for key in keys {
            XCTAssertEqual(journal.ops(for: key).last, "remove", "\(key) が外した後に書き戻された")
        }
    }

    // MARK: - 配線(RunOrchestrator は単体で組めないのでソース走査。WorkerStaggerWiringTests と同じ事情)

    private var orchestratorCode: [String] {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
            return try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        }
    }

    private func body(of signature: String, in lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix(signature) }) else { return nil }
        // 次のメソッド宣言の手前まで(この2メソッドは入れ子の関数を持たない)
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("private func ") || $0.hasPrefix("private static func ") }
            ?? lines.endIndex
        return Array(lines[(start + 1)..<end])
    }

    /// 書き込み・削除は ledger を通す(書き手のクロージャを RunOrchestrator が直に呼ぶ形に戻さない)
    func testOrchestratorWritesLeasesOnlyThroughTheLedger() throws {
        let code = try orchestratorCode.joined(separator: "\n")
        for forbidden in ["writeRunLease?(", "removeRunLease?(", "writeRecordingLease?(", "removeRecordingLease?("] {
            XCTAssertFalse(code.contains(forbidden),
                           "\(forbidden) を直に呼んでいる —— ハートビートと release の競合が戻る")
        }
    }

    /// 離脱した台の run-lease は runWorker では外さず、superviseWorker が**復帰を諦めたときだけ**外す。
    /// 離脱時に外すと、復帰(数十秒)の間にモニターの watchdog と配信がその台へ割り込む
    func testRetiredWorkerKeepsItsRunLeaseUntilTheSupervisorGivesUp() throws {
        let lines = try orchestratorCode
        guard let runWorker = body(of: "private func runWorker(", in: lines),
              let supervise = body(of: "private func superviseWorker(", in: lines) else {
            return XCTFail("runWorker / superviseWorker が見つからない(走査の前提が崩れた)")
        }
        let releasesInRunWorker = runWorker.filter { $0.contains("runLeases.release(") }
        XCTAssertEqual(releasesInRunWorker.count, 1,
                       "runWorker で run-lease を外すのは完走時の1箇所だけのはず: \(releasesInRunWorker)")
        if let retiredReturn = runWorker.firstIndex(where: { $0.contains("return .retired(failed: failed") }),
           let release = runWorker.firstIndex(where: { $0.contains("runLeases.release(") }) {
            XCTAssertGreaterThan(release, retiredReturn, "離脱の分岐で run-lease を外している")
        }
        let giveUps = supervise.filter { $0.contains("runLeases.release(retiredKey)") }
        XCTAssertEqual(giveUps.count, 3,
                       "復帰を諦める2経路 + 別キーで復帰した旧キーの3箇所で外すはず: \(giveUps)")
    }
}
