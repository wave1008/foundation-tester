// run 開始前の FM 劣化警告(`ProfileRunner.warnIfFMDegraded`)の出し分けの検証。
//
// **緑の run では1度も実行されない経路**なので、フルスイートを何度回してもここは守られない ——
// 台帳(FMLiveness)へ「死」を注入して強制的に通す陽性対照が要る(2026-09-03 に実 run で
// 二重出力の欠陥を1件見つけた箇所でもある)。
//
// 見るのは「誰の機能が無効になるか」まで言えているか: text と vision は独立に死に、
// run の中で FM を使うのは vision(occlusion-guard と screenLooksLike)だけで、text の死では何も失われない。
// 経路の名前を出すだけでは、読み手は次の一手(シナリオの書き換え / 実行機の変更)を選べない。
//
// 書き込み先は env 越しに一時ディレクトリへ逃がすが、FT_FM_LIVENESS_DIR 自体はプロセス全体の
// 状態なので SharedResource.hostCaches で直列化する(FMLivenessTests と同じ)。

import FTCore
import FTTestSupport
import XCTest
@testable import fleetest

final class FMDegradedWarningTests: XCTestCase {
    private var dir: URL!
    private var savedEnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMDegradedWarningTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedEnv = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
        setenv("FT_FM_LIVENESS_DIR", dir.path, 1)
    }

    override func tearDownWithError() throws {
        if let savedEnv { setenv("FT_FM_LIVENESS_DIR", savedEnv, 1) } else { unsetenv("FT_FM_LIVENESS_DIR") }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 鮮度の新しい台帳を置く。**新しくないと `refresh` が実呼び出しへ行く**(テストが FM に依存する)
    private func inject(text: FMLiveness.State?, vision: FMLiveness.State?) throws {
        var record = FMLiveness.Record()
        let now = Date().timeIntervalSince1970
        if let text {
            record.text = FMLiveness.Verdict(state: text, checkedAt: now, source: .probe,
                                             error: text == .dead ? "text boom" : nil)
        }
        if let vision {
            record.vision = FMLiveness.Verdict(state: vision, checkedAt: now, source: .probe,
                                               error: vision == .dead ? "vision boom" : nil)
        }
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent("fm-liveness.json"))
    }

    private func warnings(fm: FMConfig) async -> [String] {
        var lines: [String] = []
        await ProfileRunner.warnIfFMDegraded(fm: fm) { lines.append($0) }
        return lines
    }

    /// vision だけ死(実測で最も多い形)。**視覚系の名前だけを挙げる** —— 自己修復(FM を使わない)まで
    /// 巻き込んで書くと、動いているものまで「無効」と報告して読み手が警告を信じなくなる
    func testVisionOnlyDeathNamesTheVisualFeaturesOnly() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .alive, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: true,
                                                textVisualCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines.count, 1, "1経路の死に1行。\(lines)")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("vision path"), line)
        XCTAssertTrue(line.contains("occlusion-guard"), line)
        XCTAssertTrue(line.contains("screenLooksLike"), line)
        XCTAssertFalse(line.contains("self-healing"), "FM を使わない自己修復を無効と言わない。\(line)")
        XCTAssertTrue(line.contains("vision boom"), "理由まで出す。\(line)")
    }

    /// text だけ死。**run の中で text の経路を使う機能は無い**ので、FM を全部有効にした run でも黙る
    /// (無効になる機能が無いのに「無効」と言わない)
    func testTextDeathIsNeverReportedBeforeARun() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .dead, vision: .alive)
        }
        let lines = await warnings(fm: FMConfig(enabled: true,
                                                textVisualCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines, [], "\(lines)")
    }

    /// 両方死んでも言うのは vision の1行だけ(text の死で run が失う機能は無い)
    func testBothPathsDeadReportOnlyTheVisionPath() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .dead, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: true,
                                                textVisualCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("vision path") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("text path") }, "\(lines)")
    }

    /// 視覚系を使わない run では vision の死を言わない(その run では本当に何も無効になっていない)
    func testVisionDeathIsSilentForRunsThatDoNotUseVision() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .alive, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: true,
                                                textVisualCheck: false, screenLooksLike: false))
        XCTAssertEqual(lines, [], "\(lines)")
    }

    /// 生きているなら黙る(健康な機械で毎 run 警告が出ると読まれなくなる)。
    ///
    /// **「不明」はここでは検証できない** —— 不明を作るには台帳を古く/空にするしかなく、
    /// そうすると `refresh` が実呼び出しへ行ってテストが FM の生死に依存する。台帳の側で
    /// 「古い・無い → nil(不明)」は FMLivenessTests が固定してあり、この警告はその nil を
    /// 死と区別せず読むだけなので、境界はあちらに置く
    func testAliveIsSilent() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .alive, vision: .alive)
        }
        let lines = await warnings(fm: FMConfig(enabled: true,
                                                textVisualCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines, [], "\(lines)")
    }

    /// **視覚系を使わない run では死活確認そのものを撃たない**(`readLiveness` を呼ばない)。
    /// 既定の `FMLivenessProbe.refresh` は台帳が古いと FM を実際に呼ぶ(0.7〜4.7 秒・FMLock を取る)ので、
    /// 結果を捨てる run で払わせない。FM ごと切った run も同じ
    func testRunsThatDoNotUseVisionNeverReadTheLiveness() async {
        for fm in [FMConfig(enabled: true, textVisualCheck: false, screenLooksLike: false),
                   FMConfig(enabled: false, textVisualCheck: true, screenLooksLike: true)] {
            var reads = 0
            var lines: [String] = []
            await ProfileRunner.warnIfFMDegraded(fm: fm, readLiveness: {
                reads += 1
                return FMLiveness.Reading(text: nil, vision: nil)
            }) { lines.append($0) }
            XCTAssertEqual(reads, 0, "視覚系を使わない run で死活確認を撃った: \(fm)")
            XCTAssertEqual(lines, [])
        }
        // 陽性対照: 視覚系を使う run では読む(macOS 26 では視覚非対応の警告で先に抜ける)
        var reads = 0
        await ProfileRunner.warnIfFMDegraded(
            fm: FMConfig(enabled: true, textVisualCheck: true, screenLooksLike: false),
            readLiveness: { reads += 1; return FMLiveness.Reading(text: nil, vision: nil) }) { _ in }
        XCTAssertEqual(reads, FMVisionSupport.isSupported ? 1 : 0)
    }

    /// FM を使わない run(fm.enabled=false)は台帳を読みに行く前に返る。
    /// **死んでいる台帳を置いても黙る**ことで、門が enabled の側にあることを確かめる
    func testRunsThatDoNotUseFMAreSilentEvenWithADeadLedger() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .dead, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: false,
                                                textVisualCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines, [], "\(lines)")
    }
}
