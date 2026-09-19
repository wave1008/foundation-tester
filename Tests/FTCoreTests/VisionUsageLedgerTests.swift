// VisionUsageLedger(Vision / Core ML 呼び出しの機械グローバルな控え)の検証。
// 共通の機構(基準取り・pid 再利用・reap 等)は UsageLedger として FMUsageLedger と共有しており、
// そちらは FMUsageLedgerTests が守る。ここで見るのは「別インスタンスとして独立していること」
// (置き場が別・累計が混ざらない)と、実際の書き手(RegionText.read / VisionClassifier)からの配線だけ。
// 生存判定に実際の kill(2) を使うため、SharedResource.hostCaches で直列化する
// (FMUsageLedgerTests と同じ理由)。

import CoreGraphics
import FTTestSupport
import Foundation
import ImageIO
import XCTest
@testable import FTCore

final class VisionUsageLedgerTests: XCTestCase {
    private var dir: URL!
    private var savedVisionEnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VisionUsageLedgerTests-\(UUID().uuidString)")
        savedVisionEnv = ProcessInfo.processInfo.environment["FT_VISION_USAGE_DIR"]
        setenv("FT_VISION_USAGE_DIR", dir.path, 1)
        // 累計はプロセス内で持ち越される。置き場だけ新しくすると、基準取りの**後**に初めて
        // 現れる pid の増分が「そのプロセスのこれまでの累計まるごと」になる(drain の規律)
        VisionUsageLedger.resetForTesting()
    }

    override func tearDownWithError() throws {
        if let savedVisionEnv { setenv("FT_VISION_USAGE_DIR", savedVisionEnv, 1) } else { unsetenv("FT_VISION_USAGE_DIR") }
        try? FileManager.default.removeItem(at: dir)
    }

    /// FT_VISION_USAGE_DIR の下に書く(FM の控えを汚さない)。FM 側は既定の置き場(または他テストが
    /// 設定した FT_FM_USAGE_DIR)のままなので、ここでは「Vision の控えが自分の置き場の下に実際にファイルを
    /// 作る」ことだけを確かめる
    func testWritesUnderItsOwnDirectory() throws {
        try SharedResource.hostCaches.locked {
            VisionUsageLedger.record(ok: true, ms: 12)
            let selfPID = ProcessInfo.processInfo.processIdentifier
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("\(selfPID).json").path),
                "Vision の控えが FT_VISION_USAGE_DIR の下に作られていない")
        }
    }

    /// FM と Vision の累計は別インスタンス(別ファイル群)なので混ざらない ——
    /// Vision へ record してから FM を drain しても増分は出ない
    func testFMAndVisionCountersDoNotMix() throws {
        try SharedResource.hostCaches.locked {
            let fmDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VisionUsageLedgerTests-fm-\(UUID().uuidString)")
            let savedFMEnv = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"]
            setenv("FT_FM_USAGE_DIR", fmDir.path, 1)
            defer {
                if let savedFMEnv { setenv("FT_FM_USAGE_DIR", savedFMEnv, 1) } else { unsetenv("FT_FM_USAGE_DIR") }
                try? FileManager.default.removeItem(at: fmDir)
            }

            var fmPrevious: [Int32: FMUsageLedger.Counters]? = nil
            XCTAssertEqual(FMUsageLedger.drain(previous: &fmPrevious)?.calls, 0, "FM 側の基準取り")

            VisionUsageLedger.record(ok: true, ms: 5)
            VisionUsageLedger.record(ok: true, ms: 7)

            XCTAssertEqual(FMUsageLedger.drain(previous: &fmPrevious)?.calls, 0,
                           "Vision への record が FM 側の増分に漏れている")
        }
    }

    /// record → drain の増分が取れる(基準取りの回は0、以降は増分が出る)
    func testRecordThenDrainYieldsIncrement() throws {
        try SharedResource.hostCaches.locked {
            var previous: [Int32: VisionUsageLedger.Counters]? = nil

            VisionUsageLedger.record(ok: true, ms: 40)
            let first = VisionUsageLedger.drain(previous: &previous)
            XCTAssertEqual(first?.calls, 0, "初見の pid は増分0")

            VisionUsageLedger.record(ok: true, ms: 30)
            VisionUsageLedger.record(ok: false, ms: 20)
            let second = VisionUsageLedger.drain(previous: &previous)
            XCTAssertEqual(second?.calls, 2)
            XCTAssertEqual(second?.failures, 1)
            XCTAssertEqual(second?.totalMs, 50)
        }
    }

    /// batched の範囲の record は溜めて、終わりに1回だけ書く(途中ではファイルに出ない)。
    /// 件数・失敗・所要の合計は1件ずつ書いたときと同じ
    func testBatchedRecordsAreWrittenOnceWithTheSameTotals() async throws {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let file = dir.appendingPathComponent("\(selfPID).json")
        func writtenCalls() throws -> Int {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            return try XCTUnwrap(object?["calls"] as? Int)
        }
        var previous: [Int32: VisionUsageLedger.Counters]? = nil
        VisionUsageLedger.record(ok: true, ms: 1)
        _ = VisionUsageLedger.drain(previous: &previous)   // 基準取り(初見の pid は増分0)
        let before = try writtenCalls()
        try await VisionUsageLedger.batched {
            VisionUsageLedger.record(ok: true, ms: 10)
            VisionUsageLedger.record(ok: false, ms: 20)
            VisionUsageLedger.record(ok: true, ms: 30)
            XCTAssertEqual(try writtenCalls(), before, "範囲の途中では書かない")
        }
        XCTAssertEqual(try writtenCalls(), before + 3)
        let delta = VisionUsageLedger.drain(previous: &previous)
        XCTAssertEqual(delta?.calls, 3)
        XCTAssertEqual(delta?.failures, 1)
        XCTAssertEqual(delta?.totalMs, 60)
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
            var previous: [Int32: VisionUsageLedger.Counters]? = nil
            XCTAssertEqual(VisionUsageLedger.drain(previous: &previous)?.calls, 0, "基準取り")

            _ = await RegionText.read(pngData: data, frame: rect, screen: rect,
                                      languages: RegionText.defaultLanguages, upscale: 1)

            let delta = VisionUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 1, "read 1回につき控えは1件増える")
        }
    }

    // MARK: - VisionClassifier からの配線

    /// 学習1回 + 点検の推論(見本 12 枚ぶん)+ 本番の推論1回(と対照2枚)が、それぞれ1件ずつ控えへ入る。
    /// 学習と点検はロックの内側で走るので、記録が解放後にまとめて書かれることもここで見える
    func testVisionClassifierRecordsTrainingAndEachInference() async throws {
        let root = try DefaultClassifierTests.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir))
        let samples = set.labels.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(samples, 12, "この後の期待値は見本 12 枚前提")
        VisionClassifier.forgetLoadedModelsForTesting()

        try await SharedResource.hostCaches.locked {
            var previous: [Int32: VisionUsageLedger.Counters]? = nil
            XCTAssertEqual(VisionUsageLedger.drain(previous: &previous)?.calls, 0, "基準取り")

            let model = try await VisionClassifier.load(
                set, cacheDirectory: VisionClassifier.cacheDirectory(projectRoot: root, name: DefaultClassifier.name))
            XCTAssertEqual(VisionUsageLedger.drain(previous: &previous)?.calls, 1 + samples,
                           "学習1件 + 点検の推論が見本1枚につき1件")

            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
                try XCTUnwrap(CGImageSourceCreateWithData(
                    DefaultClassifierTests.iconPNG(circle: true, shift: 2) as CFData, nil)), 0, nil))
            _ = try model.classify(image)
            XCTAssertEqual(model.controls.count, 2)
            XCTAssertEqual(VisionUsageLedger.drain(previous: &previous)?.calls, 3,
                           "本番の推論1件 + 対照2枚の推論 = 推論1回につき1件")
        }
    }
}
