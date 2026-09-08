// OCRUsageLedger(OCR 呼び出しの機械グローバルな控え)の検証。
// 共通の機構(基準取り・pid 再利用・reap 等)は UsageLedger として FMUsageLedger と共有しており、
// そちらは FMUsageLedgerTests が守る。ここで見るのは「別インスタンスとして独立していること」
// (置き場が別・累計が混ざらない)と、実際の書き手(RegionText.read)からの配線だけ。
// 生存判定に実際の kill(2) を使うため、SharedResource.hostCaches で直列化する
// (FMUsageLedgerTests と同じ理由)。

import CoreGraphics
import FTTestSupport
import Foundation
import ImageIO
import XCTest
@testable import FTCore

final class OCRUsageLedgerTests: XCTestCase {
    private var dir: URL!
    private var savedOCREnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OCRUsageLedgerTests-\(UUID().uuidString)")
        savedOCREnv = ProcessInfo.processInfo.environment["FT_OCR_USAGE_DIR"]
        setenv("FT_OCR_USAGE_DIR", dir.path, 1)
        // 累計はプロセス内で持ち越される。置き場だけ新しくすると、基準取りの**後**に初めて
        // 現れる pid の増分が「そのプロセスのこれまでの累計まるごと」になる(drain の規律)
        OCRUsageLedger.resetForTesting()
    }

    override func tearDownWithError() throws {
        if let savedOCREnv { setenv("FT_OCR_USAGE_DIR", savedOCREnv, 1) } else { unsetenv("FT_OCR_USAGE_DIR") }
        try? FileManager.default.removeItem(at: dir)
    }

    /// FT_OCR_USAGE_DIR の下に書く(FM の控えを汚さない)。FM 側は既定の置き場(または他テストが
    /// 設定した FT_FM_USAGE_DIR)のままなので、ここでは「OCR が自分の置き場の下に実際にファイルを
    /// 作る」ことだけを確かめる
    func testWritesUnderItsOwnDirectory() throws {
        try SharedResource.hostCaches.locked {
            OCRUsageLedger.record(ok: true, ms: 12)
            let selfPID = ProcessInfo.processInfo.processIdentifier
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("\(selfPID).json").path),
                "OCR の控えが FT_OCR_USAGE_DIR の下に作られていない")
        }
    }

    /// FM と OCR の累計は別インスタンス(別ファイル群)なので混ざらない ——
    /// OCR へ record してから FM を drain しても増分は出ない
    func testFMAndOCRCountersDoNotMix() throws {
        try SharedResource.hostCaches.locked {
            let fmDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("OCRUsageLedgerTests-fm-\(UUID().uuidString)")
            let savedFMEnv = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"]
            setenv("FT_FM_USAGE_DIR", fmDir.path, 1)
            defer {
                if let savedFMEnv { setenv("FT_FM_USAGE_DIR", savedFMEnv, 1) } else { unsetenv("FT_FM_USAGE_DIR") }
                try? FileManager.default.removeItem(at: fmDir)
            }

            var fmPrevious: [Int32: FMUsageLedger.Counters]? = nil
            XCTAssertEqual(FMUsageLedger.drain(previous: &fmPrevious)?.calls, 0, "FM 側の基準取り")

            OCRUsageLedger.record(ok: true, ms: 5)
            OCRUsageLedger.record(ok: true, ms: 7)

            XCTAssertEqual(FMUsageLedger.drain(previous: &fmPrevious)?.calls, 0,
                           "OCR への record が FM 側の増分に漏れている")
        }
    }

    /// record → drain の増分が取れる(基準取りの回は0、以降は増分が出る)
    func testRecordThenDrainYieldsIncrement() throws {
        try SharedResource.hostCaches.locked {
            var previous: [Int32: OCRUsageLedger.Counters]? = nil

            OCRUsageLedger.record(ok: true, ms: 40)
            let first = OCRUsageLedger.drain(previous: &previous)
            XCTAssertEqual(first?.calls, 0, "初見の pid は増分0")

            OCRUsageLedger.record(ok: true, ms: 30)
            OCRUsageLedger.record(ok: false, ms: 20)
            let second = OCRUsageLedger.drain(previous: &previous)
            XCTAssertEqual(second?.calls, 2)
            XCTAssertEqual(second?.failures, 1)
            XCTAssertEqual(second?.totalMs, 50)
        }
    }

    // MARK: - RegionText.read からの配線

    /// `Tests/FTCoreTests/このファイル` から相対に `Tests/Fixtures/OcclusionCrops` を指す
    /// (RegionTextCorpusTests と同じフィクスチャ)
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OcclusionCrops")
    }

    private func png(_ name: String) throws -> (data: Data, rect: FTRect) {
        let url = fixtureDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (data, FTRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height)))
    }

    /// `RegionText.read` が実際に `recognize` を撃った回だけ控えへ書く。Vision の可否で ok の真偽が
    /// フレークしうる環境を避けるため、見るのは **calls が1増えること**だけ(暖機は read を経由
    /// しないので混ざらないことも同時に見える —— 暖機ぶんまで足されるなら +1 では止まらない)
    func testRegionTextReadRecordsExactlyOneCall() async throws {
        try await SharedResource.hostCaches.locked {
            let (data, rect) = try png("swipe-down.png")
            var previous: [Int32: OCRUsageLedger.Counters]? = nil
            XCTAssertEqual(OCRUsageLedger.drain(previous: &previous)?.calls, 0, "基準取り")

            _ = await RegionText.read(pngData: data, frame: rect, screen: rect,
                                      languages: RegionText.defaultLanguages, upscale: 1)

            let delta = OCRUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 1, "read 1回につき控えは1件増える")
        }
    }
}
