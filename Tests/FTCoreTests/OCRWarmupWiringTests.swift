// 認識器のコンパイルキャッシュを**シナリオ実行バイナリと同じプロセス名**でコミットさせる暖機
// (`ScenarioHost.warmOCRCache` / `RegionText.commitCompileCache`)の配線。
// - 読ませる言語集合は `languages(for:)` が返しうる集合と**等しい**(片方だけ暖めると、
//   もう片方の初回読みが 20〜45 秒のまま残る)
// - 起こすのは run の2経路(fleetest run / api run)だけ(dry-run や MCP の一覧取得で Vision を読ませない)

import Foundation
import XCTest
@testable import FTCore

final class OCRWarmupWiringTests: XCTestCase {

    func testWarmupCoversExactlyTheLanguageSetsTheRuleCanProduce() {
        let produced: Set<[String]> = [RegionText.languages(for: "qty=0"),          // ASCII
                                       RegionText.languages(for: "ログイン")]        // 非 ASCII
        XCTAssertEqual(Set(RegionText.warmupLanguageSets), produced,
                       "暖機の言語集合が languages(for:) の返しうる集合と一致していない")
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// 暖機を起こすのは**シナリオを実際に走らせる**3経路(`listForRun`)だけ。
    /// fleet --split / api の機械 fan-out は子(`run --runner local` / `api run`)がこの3経路を通るので
    /// 自分では起こさない。一覧だけの経路(dry-run / MCP / codegen)は `list` のまま
    func testOnlyTheRunPathsStartTheWarmup() throws {
        var forRun: Set<String> = [], direct: Set<String> = []
        let fm = FileManager.default
        for case let path as String in fm.enumerator(atPath: sources.path)! where path.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            let name = (path as NSString).lastPathComponent
            if text.contains("ScenarioHost.listForRun(") { forRun.insert(name) }
            if text.contains("warmOCRCache(") && name != "ScenarioHost.swift" { direct.insert(name) }
        }
        XCTAssertEqual(forRun, ["Fleetest.swift", "ApiRunCommand.swift", "DeviceMachineRunner.swift"],
                       "listForRun の呼び出し元が run の3経路と一致しない(増減したらこの表と理由を更新する)")
        XCTAssertEqual(direct, [], "暖機は listForRun 経由でだけ起こす(直接呼ぶと一覧だけの経路にも漏れる)")
        // listForRun 自身が暖機を起こしていること(呼び出し元の走査だけだと、本体から消しても緑)
        let host = try String(contentsOf: sources.appendingPathComponent("FTCore/ScenarioHost.swift"), encoding: .utf8)
        let body = host.components(separatedBy: "static func listForRun(").dropFirst().first.map { String($0.prefix(300)) } ?? ""
        XCTAssertTrue(body.contains("warmOCRCache(project: project)"), "listForRun が暖機を起こしていない: \(body)")
    }
}

/// `warm-ocr` は機械で同時に 1 本(OCRWarmupLock)。2 本目は取れない・所有者が閉じれば取れる
final class OCRWarmupLockTests: XCTestCase {
    func testSecondAcquireFailsWhileTheFirstIsHeldAndSucceedsAfterRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-warmup-lock-\(UUID().uuidString)")
        let first = try XCTUnwrap(OCRWarmupLock.tryAcquire(processName: "fleetest-scenarios-X", directory: dir))
        XCTAssertNil(OCRWarmupLock.tryAcquire(processName: "fleetest-scenarios-X", directory: dir), "同じ名前の 2 本目が取れてしまう")
        XCTAssertNotNil(OCRWarmupLock.tryAcquire(processName: "fleetest-scenarios-Y", directory: dir), "別の名前(別のキャッシュ)は独立")
        try first.close()
        XCTAssertNotNil(OCRWarmupLock.tryAcquire(processName: "fleetest-scenarios-X", directory: dir), "所有者が閉じても取れない(永久に塞ぐ)")
    }
}

/// `acquire`(待つ版)は**所有者が離すまで待つ**。待たずに返ると 8 レーンが同じモデルを同時に焼く
final class OCRWarmupLockWaitTests: XCTestCase {
    func testAcquireWaitsForTheHolderToRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-warmup-wait-\(UUID().uuidString)")
        let holder = try XCTUnwrap(OCRWarmupLock.tryAcquire(processName: "fleetest-scenarios-Z", directory: dir))
        let releaser = Thread { Thread.sleep(forTimeInterval: 0.4); try? holder.close() }
        releaser.start()
        let start = Date()
        let acquired = OCRWarmupLock.acquire(processName: "fleetest-scenarios-Z", directory: dir)
        let waited = Date().timeIntervalSince(start)
        XCTAssertNotNil(acquired)
        XCTAssertGreaterThanOrEqual(waited, 0.3, "所有者が離す前に取れている(待っていない)")
    }
}
