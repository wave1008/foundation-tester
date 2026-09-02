// run 開始前の FM 劣化警告(`ProfileRunner.warnIfFMDegraded`)の出し分けの検証。
//
// **緑の run では1度も実行されない経路**なので、フルスイートを何度回してもここは守られない ——
// 台帳(FMLiveness)へ「死」を注入して強制的に通す陽性対照が要る(2026-09-03 に実 run で
// 二重出力の欠陥を1件見つけた箇所でもある)。
//
// 見るのは「誰の機能が無効になるか」まで言えているか: text と vision は独立に死に、
// 無効になる機能が違う(text=自己修復とトリアージ / vision=occlusion-guard と screenLooksLike)。
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

    /// vision だけ死(実測で最も多い形)。**視覚系の名前だけを挙げる** ——
    /// text 系まで巻き込んで書くと、直っているものまで「無効」と報告して読み手が警告を信じなくなる
    func testVisionOnlyDeathNamesTheVisualFeaturesOnly() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .alive, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: true, heal: false,
                                                falsePositiveCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines.count, 1, "1経路の死に1行。\(lines)")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("vision path"), line)
        XCTAssertTrue(line.contains("occlusion-guard"), line)
        XCTAssertTrue(line.contains("screenLooksLike"), line)
        XCTAssertFalse(line.contains("self-healing"), "生きている text 系を無効と言わない。\(line)")
        XCTAssertTrue(line.contains("vision boom"), "理由まで出す。\(line)")
    }

    /// text だけ死。**heal を切っていても出す** —— triage は heal と無関係に FM を引く。
    /// 2026-09-03 まで「--heal のときだけ」だったので、この形の run は開始前に何も言わなかった
    func testTextDeathIsReportedEvenWhenHealIsOff() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .dead, vision: .alive)
        }
        let lines = await warnings(fm: FMConfig(enabled: true, heal: false,
                                                falsePositiveCheck: false, screenLooksLike: false))
        XCTAssertEqual(lines.count, 1, "\(lines)")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("text path"), line)
        XCTAssertTrue(line.contains("self-healing"), line)
        XCTAssertTrue(line.contains("text boom"), line)
    }

    /// 両方死んだら両方言う(無効になる機能の集合が違うので1行に畳まない)
    func testBothPathsDeadProduceOneLineEach() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .dead, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: true, heal: true,
                                                falsePositiveCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("text path") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("vision path") }, "\(lines)")
    }

    /// 視覚系を使わない run では vision の死を言わない(その run では本当に何も無効になっていない)
    func testVisionDeathIsSilentForRunsThatDoNotUseVision() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .alive, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: true, heal: true,
                                                falsePositiveCheck: false, screenLooksLike: false))
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
        let lines = await warnings(fm: FMConfig(enabled: true, heal: true,
                                                falsePositiveCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines, [], "\(lines)")
    }

    /// FM を使わない run(fm.enabled=false)は台帳を読みに行く前に返る。
    /// **死んでいる台帳を置いても黙る**ことで、門が enabled の側にあることを確かめる
    func testRunsThatDoNotUseFMAreSilentEvenWithADeadLedger() async throws {
        try SharedResource.hostCaches.locked {
            try inject(text: .dead, vision: .dead)
        }
        let lines = await warnings(fm: FMConfig(enabled: false, heal: true,
                                                falsePositiveCheck: true, screenLooksLike: true))
        XCTAssertEqual(lines, [], "\(lines)")
    }
}
