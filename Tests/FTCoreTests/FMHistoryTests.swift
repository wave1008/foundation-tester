// FMHistory(FM の観測の追記式の履歴)の検証。見るのは規律そのもの: 生の連投は書かない / 同じ失敗は畳む /
// 変わり目を書く / 死に変わったら証拠を添える / 期間と容量で古い行を捨てる。
// 置き場は FMLivenessTests と同じく FT_FM_LIVENESS_DIR へ逃がし、SharedResource.hostCaches で直列化する。

import FTTestSupport
import XCTest
@testable import FTCore


/// テスト用: 壁時計の時刻をそのまま刻印の順序へ写す(同じ起動・ns)。`now:` で順序を表すテストに使う
fileprivate extension FMLiveness.Stamp {
    static func at(_ date: Date) -> FMLiveness.Stamp {
        FMLiveness.Stamp(boot: FMLiveness.Stamp.now().boot, mono: UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000))
    }
}

final class FMHistoryTests: XCTestCase {
    private var dir: URL!
    private var savedEnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMHistoryTests-\(UUID().uuidString)")
        savedEnv = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
        setenv("FT_FM_LIVENESS_DIR", dir.path, 1)
        FMLiveness.resetWriteMemo()
    }

    override func tearDownWithError() throws {
        // 裏の証拠取得を待ち切ってから戻す(戻した後に走ると本番の置き場・取得口を使いうる)
        FMHistory.waitForPendingEvidence()
        FMHistory.evidenceProvider.withLock { $0 = { FMHistory.aneLogEvidence() } }
        if let savedEnv { setenv("FT_FM_LIVENESS_DIR", savedEnv, 1) } else { unsetenv("FT_FM_LIVENESS_DIR") }
        FMLiveness.resetWriteMemo()
        try? FileManager.default.removeItem(at: dir)
    }

    private func events() -> [FMHistory.Event] { FMHistory.recent(limit: 1000) }

    private func lineCount() -> Int {
        let data = (try? Data(contentsOf: dir.appendingPathComponent("fm-history.ndjson"))) ?? Data()
        return data.split(separator: 0x0A).count
    }

    func testRetentionLimitsArePinned() {
        XCTAssertEqual(FMHistory.maxBytes, 5_242_880)
        XCTAssertEqual(FMHistory.maxAgeSeconds, 2_592_000)
        XCTAssertEqual(FMHistory.pruneTargetRatio, 0.9)
        XCTAssertEqual(FMHistory.tailWindowBytes, 16_384)
        XCTAssertEqual(FMHistory.evidenceWindowMinutes, 5)
        XCTAssertEqual(FMHistory.evidenceMaxLines, 5)
        XCTAssertEqual(FMHistory.evidenceTimeoutSeconds, 20)
    }

    private var historyURL: URL { dir.appendingPathComponent("fm-history.ndjson") }

    private func writeLines(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(lines.joined().utf8).write(to: historyURL)
    }

    private func line(_ event: FMHistory.Event) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n"
    }

    /// 履歴がリンクに差し替えられていたら、リンク先を書き換えない(サンドボックスの中から差し替えられる)
    func testASymlinkedHistoryIsNotFollowed() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("outside.txt")
            try Data("keep".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: historyURL, withDestinationURL: target)
            FMHistory.recordFailure(path: .vision, source: .probe, error: "boom", ms: 1)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep", "リンク先を書き換えた")
        }
    }

    /// 書き込みの途中で死んだ半端な末尾は切り戻す(次の行が連結して読めなくならない)
    func testAPartialTailIsCutBackBeforeAppending() throws {
        try SharedResource.hostCaches.locked {
            let ok = FMHistory.Event(kind: .died, path: .text, source: .probe, error: "e", at: Date().timeIntervalSince1970)
            try writeLines([try line(ok), "{\"kind\":\"fai"])
            FMHistory.recordFailure(path: .vision, source: .call, error: "next", ms: 1)
            XCTAssertEqual(events().map(\.kind), [.died, .failure])
            XCTAssertEqual(events().last?.error, "next")
        }
    }

    /// 行は時刻順とは限らない: 期限切れの行を個別に捨て、間に挟まった期間内の行は残す
    func testOutOfOrderLinesArePrunedOneByOne() throws {
        try SharedResource.hostCaches.locked {
            let now = Date().timeIntervalSince1970
            let old = now - FMHistory.maxAgeSeconds - 86_400
            try writeLines([
                try line(.init(kind: .failure, path: .text, source: .probe, error: "old1", at: old)),
                try line(.init(kind: .failure, path: .text, source: .probe, error: "A", at: now - 60)),
                try line(.init(kind: .failure, path: .text, source: .probe, error: "old2", at: old)),
                try line(.init(kind: .failure, path: .text, source: .probe, error: "C", at: now - 30)),
            ])
            FMHistory.recordFailure(path: .vision, source: .call, error: "D", ms: 1)
            XCTAssertEqual(events().map(\.error), ["A", "C", "D"])
        }
    }

    /// 先頭の行が読めないときも掃除を走らせ、読めない行を捨てる
    func testAnUnreadableHeadTriggersThePrune() throws {
        try SharedResource.hostCaches.locked {
            try writeLines(["not json\n",
                            try line(.init(kind: .failure, path: .text, source: .probe, error: "A",
                                           at: Date().timeIntervalSince1970))])
            FMHistory.recordFailure(path: .vision, source: .call, error: "B", ms: 1)
            XCTAssertEqual(lineCount(), 2, "読めない行が残った")
            XCTAssertEqual(events().map(\.error), ["A", "B"])
        }
    }

    /// 捨てるときの書き直しは一時ファイル → rename(先頭まで切り詰めてから書くと、途中で死んだとき全部失う)
    func testPruneRewritesThroughATemporaryFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/FMHistory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private static func pruneIfNeeded"))
        let end = try XCTUnwrap(text.range(of: "private static func openLocked"))
        let body = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("rename(tmp.path, url.path)"))
        XCTAssertFalse(body.contains("truncate(atOffset: 0)"))
    }

    /// 最も古い時刻の控えは本体より先に書く(本体の後・控えの前に死ぬと、控えが古い行を知らず掃除を取り逃す)
    func testTheOldestMarkerIsWrittenBeforeTheBody() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/FMHistory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private static func append("))
        let end = try XCTUnwrap(text.range(of: "private static func scanOldest"))
        let body = text[start.upperBound..<end.lowerBound]
        let marker = try XCTUnwrap(body.range(of: "writeOldest(oldest, to: oldestURL)"))
        let write = try XCTUnwrap(body.range(of: "try handle.write(contentsOf: data)"))
        XCTAssertLessThan(marker.lowerBound, write.lowerBound)
    }

    /// 控えを書けず消せもしないときは本体を書かない(控えが古い行を知らないまま進むと掃除を取り逃す)
    func testTheBodyIsNotWrittenWhenTheOldestMarkerCanBeNeitherWrittenNorRemoved() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let marker = dir.appendingPathComponent("fm-history.oldest")
            try Data("1e18".utf8).write(to: marker)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: marker.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: marker.path) }
            FMHistory.recordFailure(path: .vision, source: .call, error: "old", ms: 1,
                                    now: Date().addingTimeInterval(-FMHistory.maxAgeSeconds - 86_400))
            XCTAssertEqual(lineCount(), 0, "控えを書けないまま本体へ古い行を足した")
        }
    }

    /// 控えを書けないが消せるときは、消して全体の読み直しへ戻す(期間外の行を取り逃さない)
    func testAnUnwritableButRemovableMarkerFallsBackToAFullScan() throws {
        try SharedResource.hostCaches.locked {
            let now = Date().timeIntervalSince1970
            try writeLines([try line(.init(kind: .failure, path: .text, source: .probe, error: "old",
                                           at: now - FMHistory.maxAgeSeconds - 86_400))])
            // 空のディレクトリ = rename で上書きできない・消せる
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("fm-history.oldest"),
                                                    withIntermediateDirectories: true)
            FMHistory.recordFailure(path: .vision, source: .call, error: "new", ms: 1)
            XCTAssertEqual(events().map(\.error), ["new"])
        }
    }

    /// エラーはバイト数で切る(文字数で切ると多バイト・結合文字で上限にならない)
    func testErrorsAreTruncatedByUTF8BytesOnScalarBoundaries() {
        let text = String(repeating: "あ", count: 500)
        let cut = FMHistory.truncated(text, maxBytes: 600)
        XCTAssertLessThanOrEqual(cut.utf8.count, 600)
        XCTAssertEqual(cut.utf8.count, 600, "あ = 3 バイトなので 200 文字ちょうど")
        XCTAssertEqual(FMHistory.errorLimit, 600)
    }

    /// 変わり目は台帳のロックを握ったまま書く(外で書くと died / recovered の順が台帳と入れ替わる)
    func testTransitionsAreWrittenInsideTheLedgerLock() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/FMLiveness.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private static func update(path: Path"))
        let end = try XCTUnwrap(text.range(of: "private static func writeAtomically"))
        let body = text[start.upperBound..<end.lowerBound]
        let lock = try XCTUnwrap(body.range(of: "defer { close(lockFD) }"))
        let landed = try XCTUnwrap(body.range(of: "guard writeAtomically(record, to: url) else { return basis }"),
                                   "台帳を書けなかった回も変わり目を書いている")
        let transition = try XCTUnwrap(body.range(of: "FMHistory.recordTransition("), "変わり目が台帳の臨界区間の中に無い")
        XCTAssertLessThan(lock.lowerBound, landed.lowerBound)
        XCTAssertLessThan(landed.lowerBound, transition.lowerBound)
        XCTAssertEqual(text.components(separatedBy: "FMHistory.recordTransition(").count, 2, "変わり目をロックの外でも書いている")
    }

    /// TERM を無視する子も止める(TERM の後に KILL)
    func testSelfBoundedKillsAChildThatIgnoresTerm() throws {
        let started = Date()
        _ = try Shell.run(FMHistory.selfBounded(["/bin/sh", "-c", "trap '' TERM; while true; do /bin/sleep 1; done"],
                                                seconds: 1), timeout: 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "TERM を無視する子が止まらなかった")
    }

    /// 先頭の行が新しく、途中に期間外の行がある小さいファイルも掃除する(先頭だけでは決めない)
    func testAStaleLineBehindAFreshHeadIsPruned() throws {
        try SharedResource.hostCaches.locked {
            let now = Date().timeIntervalSince1970
            try writeLines([
                try line(.init(kind: .failure, path: .text, source: .probe, error: "A", at: now - 60)),
                try line(.init(kind: .failure, path: .text, source: .probe, error: "old",
                               at: now - FMHistory.maxAgeSeconds - 86_400)),
            ])
            FMHistory.recordFailure(path: .vision, source: .call, error: "C", ms: 1)
            XCTAssertEqual(events().map(\.error), ["A", "C"])
        }
    }

    /// 子は自分の期限で止まる(親の期限は親が先に終わると効かない)
    func testSelfBoundedChildStopsAtItsOwnDeadline() throws {
        let started = Date()
        let result = try Shell.run(FMHistory.selfBounded(["/bin/sleep", "30"], seconds: 1), timeout: 15)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "見張りが子を止めなかった")
        XCTAssertNotEqual(result.status, 0)
    }

    /// 証拠の取得口と置き場は依頼した時点で固定する(後から差し替えても、依頼した側の口・置き場を使う)
    func testEvidenceUsesTheProviderAndPlaceCapturedAtRequestTime() throws {
        try SharedResource.hostCaches.locked {
            let gate = DispatchSemaphore(value: 0)
            FMHistory.evidenceQueue.async { gate.wait() }
            FMHistory.evidenceProvider.withLock { $0 = { ["aned: no memory"] } }
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "boom", observed: .now())
            FMHistory.evidenceProvider.withLock { $0 = { nil } }
            gate.signal()
            FMHistory.waitForPendingEvidence()
            XCTAssertEqual(events().filter { $0.kind == .evidence }.first?.lines, ["aned: no memory"])
        }
    }

    /// 同じ経路・書き手・エラーの失敗は1行に畳み、エラーが変われば新しい行
    func testIdenticalFailuresCollapseIntoOneLine() throws {
        try SharedResource.hostCaches.locked {
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for i in 0..<3 {
                FMHistory.recordFailure(path: .vision, source: .call, error: "boom", ms: 90 + i,
                                        now: t0.addingTimeInterval(Double(i)))
            }
            FMHistory.recordFailure(path: .vision, source: .call, error: "other", ms: 1, now: t0.addingTimeInterval(9))
            let all = events()
            XCTAssertEqual(all.count, 2)
            XCTAssertEqual(all[0].count, 3)
            XCTAssertEqual(all[0].at, t0.timeIntervalSince1970)
            XCTAssertEqual(all[0].lastAt, t0.addingTimeInterval(2).timeIntervalSince1970)
            XCTAssertEqual(all[1].error, "other")
            XCTAssertNil(all[1].count)
        }
    }

    /// 台帳の死は died、生に戻れば recovered。**生の連投は書かない**。プローブの失敗の行は settle が書く
    /// (`FMLivenessProbeThresholdTests` が配線を縛る)ので、ここ(台帳への直接の記録)では出ない
    func testProbeDeathAndRecoveryAreRecordedButAliveRepeatsAreNot() throws {
        try SharedResource.hostCaches.locked {
            FMHistory.evidenceProvider.withLock { $0 = { nil } }
            let t0 = Date()
            FMLiveness.record(path: .text, state: .alive, source: .probe, ms: 300, now: t0, observed: .at(t0))
            FMLiveness.record(path: .text, state: .alive, source: .probe, ms: 300, now: t0.addingTimeInterval(60), observed: .at(t0.addingTimeInterval(60)))
            XCTAssertEqual(events(), [], "生の観測は書かない(初めての生も変わり目ではない)")
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "ModelManagerError 1001",
                              now: t0.addingTimeInterval(120), observed: .at(t0.addingTimeInterval(120)))
            FMLiveness.record(path: .text, state: .alive, source: .probe, ms: 300, now: t0.addingTimeInterval(180), observed: .at(t0.addingTimeInterval(180)))
            FMHistory.waitForPendingEvidence()
            XCTAssertEqual(events().map(\.kind), [.died, .recovered])
            XCTAssertEqual(events()[0].error, "ModelManagerError 1001")
            XCTAssertEqual(events()[0].source, .probe)
        }
    }

    /// 呼ばずに決めた死(availability・ブレーカ)は、台帳への記録が失敗の行も書く(他に書く場所が無い)
    func testAvailabilityDeathWritesAFailureLineToo() throws {
        try SharedResource.hostCaches.locked {
            FMHistory.evidenceProvider.withLock { $0 = { nil } }
            FMLiveness.record(path: .vision, state: .dead, source: .availability, error: "Apple Intelligence is off",
                              observed: .now())
            FMHistory.waitForPendingEvidence()
            XCTAssertEqual(events().map(\.kind), [.failure, .died])
            XCTAssertEqual(events()[0].source, .availability)
        }
    }

    /// 実呼び出しの失敗は閾値未満でも1回ずつ残り、閾値の回は「死に変わった」が1行足されるだけ(失敗を二重に書かない)
    func testCallFailuresAreRecordedOnceEachAndTheThresholdAddsOneDiedLine() throws {
        try SharedResource.hostCaches.locked {
            FMHistory.evidenceProvider.withLock { $0 = { nil } }
            FMHealth.reset()
            defer { FMHealth.reset() }
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertEqual(events().map(\.kind), [.failure], "閾値未満の失敗も履歴には残る")
            for _ in 1..<FMBreaker.threshold {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            }
            FMHistory.waitForPendingEvidence()
            XCTAssertEqual(events().map(\.kind), [.failure, .died])
            XCTAssertEqual(events()[0].count, FMBreaker.threshold)
        }
    }

    /// 死に変わった回は OS 側の証拠を別の行で足す
    func testDeathAddsTheEvidenceLines() throws {
        try SharedResource.hostCaches.locked {
            FMHistory.evidenceProvider.withLock { $0 = { ["aned: Program load failed — no memory"] } }
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "boom", observed: .now())
            FMHistory.waitForPendingEvidence()
            let evidence = events().filter { $0.kind == .evidence }
            XCTAssertEqual(evidence.count, 1)
            XCTAssertEqual(evidence.first?.lines, ["aned: Program load failed — no memory"])
            XCTAssertEqual(evidence.first?.path, .vision)
        }
    }

    func testEvidenceLinesKeepOnlyTheDeathMarks() {
        let log = """
        10:00:01 aned: loaded model
        10:00:02 aned: Program load failed — no memory (transient)
        10:00:03 TGOnDeviceInferenceProviderService: Error Domain=com.apple.appleneuralengine Code=53
        10:00:04 aned: idle
        """
        XCTAssertEqual(FMHistory.evidenceLines(from: log)?.count, 2)
        XCTAssertNil(FMHistory.evidenceLines(from: "10:00:01 aned: loaded model"))
    }

    /// 期間を過ぎた行は次の書き込みで捨てる
    func testLinesOlderThanTheRetentionPeriodAreDropped() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMHistory.recordFailure(path: .text, source: .probe, error: "old", ms: 1,
                                    now: now.addingTimeInterval(-(FMHistory.maxAgeSeconds + 86_400)))
            FMHistory.recordFailure(path: .text, source: .probe, error: "new", ms: 1, now: now)
            XCTAssertEqual(events().map(\.error), ["new"])
        }
    }

    /// 容量を超えたら新しい側から 90% に収まるぶんだけ残す(最新の行は必ず残る)
    func testOversizedHistoryIsTrimmedFromTheOldestSide() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filler = FMHistory.Event(kind: .failure, path: .text, source: .probe,
                                         error: String(repeating: "x", count: 1000), at: Date().timeIntervalSince1970)
            var line = try JSONEncoder().encode(filler)
            line.append(0x0A)
            var data = Data()
            while data.count <= FMHistory.maxBytes { data.append(line) }
            try data.write(to: dir.appendingPathComponent("fm-history.ndjson"))
            FMHistory.recordFailure(path: .vision, source: .call, error: "latest", ms: 1)
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent("fm-history.ndjson").path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, Int(Double(FMHistory.maxBytes) * 0.9))
            XCTAssertGreaterThan(lineCount(), 1000)
            XCTAssertEqual(events().last?.error, "latest")
        }
    }

    func testDescribeNamesTheKindPathAndCount() {
        let event = FMHistory.Event(kind: .failure, path: .vision, source: .call, error: "boom",
                                    at: 1_800_000_000, lastAt: 1_800_000_060, count: 7)
        let text = FMHistory.describe(event)
        XCTAssertTrue(text.contains("vision failed ×7 until"), text)
        XCTAssertTrue(text.hasSuffix("(call): boom"), text)
    }
}
