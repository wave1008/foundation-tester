// [PoC occlusion-guard 計測ハーネス]
// OcclusionVerifier(FM 視覚照合)の正確性と速度を、正解ラベル付き合成フィクスチャで測る。
// アクセシビリティツリーが「要素は存在する」と主張しても、描画上は覆われ/切れ/減光/不在で
// 見えていない偽陽性を FM がどれだけ正しく弾けるか(見逃し=偽陽性残存、誤反転=正しい要素を却下)を定量化する。
//
// 使い方: swift run ftester-poc-occlusion [出力ディレクトリ]
// 出力: <dir>/fixtures/*.png(生成画像), <dir>/report.md, <dir>/results.json
//
// 注意: 実機/シミュレータ不要(スクショを CoreGraphics で合成)。FM はオンデバイス実行。

import AppKit
import CoreGraphics
import Foundation
import FTAgent
import FTCore

// MARK: - フィクスチャ定義

enum Category: String, CaseIterable {
    case visible          // 期待テキストが明瞭に描画(正: 見える)
    case coveredFull      // 期待テキストの全面を不透明矩形で覆う(正: 見えない)
    case coveredPartial   // 期待テキストの左 65% を覆う(正: 見えない)
    case dimmed           // 期待テキストを alpha 0.12 で薄く描画(正: 見えない)
    case absent           // 領域に何も描かない(ツリーは存在を主張=不在偽陽性, 正: 見えない)
    case mismatch         // 領域に別テキストを描く(正: 見えない)

    /// このカテゴリで assert は本来 pass すべきか(=期待テキストが視覚的に見えるか)
    var shouldBeVisible: Bool { self == .visible }
}

struct Fixture {
    let id: String
    let expectedText: String
    let frame: FTRect       // logical(pt)座標。原点は左上
    let category: Category
    let png: Data
}

// logical 画面(iPhone 相当)。スクショは renderScale 倍のピクセルで生成し pt→px 換算を実地で通す。
let logicalScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
let renderScale: CGFloat = 2

let sampleTexts = [
    "ログインに成功しました",
    "Order #4821 confirmed",
    "残高 ¥12,500",
]
let mismatchTexts = [
    "エラーが発生しました",
    "Order #9999 cancelled",
    "残高 ¥0",
]

let targetFrame = FTRect(x: 40, y: 430, width: 322, height: 30)

// MARK: - 描画(AppKit で logical 座標を左上原点として扱い renderScale 倍で焼く)

func renderPNG(_ body: (CGContext) -> Void) -> Data {
    let w = Int(logicalScreen.width * renderScale)
    let h = Int(logicalScreen.height * renderScale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsctx
    let cg = nsctx.cgContext
    // 左上原点に統一(AppKit の既定は左下原点)
    cg.translateBy(x: 0, y: CGFloat(h))
    cg.scaleBy(x: renderScale, y: -renderScale)
    body(cg)
    nsctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func fillRect(_ cg: CGContext, _ r: FTRect, _ color: NSColor) {
    cg.setFillColor(color.cgColor)
    cg.fill(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
}

// logical 左上原点で文字を描く。CGContext は上で y 反転済みなので、テキストは一旦正立させて描く。
func drawText(_ cg: CGContext, _ text: String, at frame: FTRect, size: CGFloat = 20,
              color: NSColor = .black, alpha: CGFloat = 1) {
    cg.saveGState()
    // 反転座標系のままだと文字が上下逆になるため、行の位置で再反転する
    cg.translateBy(x: 0, y: frame.y * 2 + frame.height)
    cg.scaleBy(x: 1, y: -1)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size),
        .foregroundColor: color.withAlphaComponent(alpha),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    cg.textPosition = CGPoint(x: frame.x + 4, y: frame.y + 6)
    CTLineDraw(line, cg)
    cg.restoreGState()
}

func baseScreen(_ cg: CGContext) {
    fillRect(cg, logicalScreen, NSColor(white: 0.98, alpha: 1))
    fillRect(cg, FTRect(x: 0, y: 0, width: 402, height: 88), NSColor(white: 0.93, alpha: 1))
    drawText(cg, "マイページ", at: FTRect(x: 24, y: 48, width: 200, height: 26), size: 18, color: .darkGray)
    // 文脈用ディストラクタ(「画面に文字があれば可視」と短絡できないように)
    drawText(cg, "お知らせ", at: FTRect(x: 40, y: 150, width: 200, height: 24), size: 15, color: .gray)
    drawText(cg, "設定", at: FTRect(x: 40, y: 760, width: 120, height: 24), size: 15, color: .gray)
    // ターゲットが載るカード
    fillRect(cg, FTRect(x: 24, y: 410, width: 354, height: 70), NSColor.white)
}

func makeFixture(text: String, mismatch: String, index: Int, category: Category) -> Fixture {
    let png = renderPNG { cg in
        baseScreen(cg)
        switch category {
        case .visible:
            drawText(cg, text, at: targetFrame)
        case .coveredFull:
            drawText(cg, text, at: targetFrame)
            fillRect(cg, FTRect(x: targetFrame.x - 6, y: targetFrame.y - 4,
                                width: targetFrame.width + 12, height: targetFrame.height + 8),
                     NSColor.systemIndigo)
        case .coveredPartial:
            drawText(cg, text, at: targetFrame)
            fillRect(cg, FTRect(x: targetFrame.x - 6, y: targetFrame.y - 4,
                                width: targetFrame.width * 0.65 + 6, height: targetFrame.height + 8),
                     NSColor.systemTeal)
        case .dimmed:
            drawText(cg, text, at: targetFrame, color: .black, alpha: 0.12)
        case .absent:
            break // 何も描かない
        case .mismatch:
            drawText(cg, mismatch, at: targetFrame)
        }
    }
    return Fixture(id: "\(category.rawValue)-\(index)", expectedText: text,
                   frame: targetFrame, category: category, png: png)
}

// MARK: - 計測

struct Trial {
    let fixtureID: String
    let category: Category
    let arm: String          // "cropped" / "full"
    let groundTruthVisible: Bool
    let verdictVisible: Bool?  // nil = FM 判定不能
    let state: String
    let reason: String
    let latencyMs: Int
}

func run() async {
    let outDir = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : FileManager.default.temporaryDirectory.appendingPathComponent("occlusion-poc").path
    let fixturesDir = (outDir as NSString).appendingPathComponent("fixtures")
    try? FileManager.default.createDirectory(atPath: fixturesDir, withIntermediateDirectories: true)

    let doc = FMDoctor.check()
    print("FM: \(doc.detail)")
    guard doc.available else { print("FM 不可のため中断"); exit(1) }

    // フィクスチャ生成
    var fixtures: [Fixture] = []
    for (i, text) in sampleTexts.enumerated() {
        for cat in Category.allCases {
            let f = makeFixture(text: text, mismatch: mismatchTexts[i], index: i, category: cat)
            fixtures.append(f)
            try? f.png.write(to: URL(fileURLWithPath: (fixturesDir as NSString).appendingPathComponent("\(f.id).png")))
        }
    }
    print("フィクスチャ生成: \(fixtures.count) 枚(\(sampleTexts.count) テキスト × \(Category.allCases.count) カテゴリ)\n")

    let verifier = OcclusionVerifier()
    var trials: [Trial] = []
    let clock = ContinuousClock()

    for f in fixtures {
        for arm in ["cropped", "full"] {
            let start = clock.now
            let r: OcclusionVerifier.Result?
            if arm == "cropped" {
                r = await verifier.verifyCropped(expectedText: f.expectedText, frame: f.frame,
                                                 screen: logicalScreen, screenshotPNG: f.png)
            } else {
                r = await verifier.verifyFull(expectedText: f.expectedText, frame: f.frame,
                                              screen: logicalScreen, screenshotPNG: f.png)
            }
            let ms = Int((clock.now - start) / .milliseconds(1))
            let t = Trial(fixtureID: f.id, category: f.category, arm: arm,
                          groundTruthVisible: f.category.shouldBeVisible,
                          verdictVisible: r?.visible, state: r?.state ?? "nil",
                          reason: r?.reason ?? "(判定不能)", latencyMs: ms)
            trials.append(t)
            let mark = r.map { $0.visible == f.category.shouldBeVisible ? "✓" : "✗" } ?? "?"
            print("[\(mark)] \(arm.padding(toLength: 7, withPad: " ", startingAt: 0)) \(f.id.padding(toLength: 18, withPad: " ", startingAt: 0)) visible=\(r?.visible.description ?? "nil") state=\(r?.state ?? "-") \(ms)ms")
        }
    }

    // 事前フィルタ(Tier 1: ピクセル分散)の計測と、ゲート後パイプラインのシミュレーション。
    // ゲート規則: stddev >= 閾値 なら「明瞭にインクあり=見えている」とみなし FM 省略(visible=true 相当)。
    //           stddev <  閾値 なら疑いとして FM(cropped)へ回す。
    var ink: [String: Double] = [:]
    print("\n--- 事前フィルタ(領域輝度 stddev) ---")
    for f in fixtures {
        let sd = RegionInk.luminanceStdDev(pngData: f.png, frame: f.frame, screen: logicalScreen) ?? -1
        ink[f.id] = sd
        print("  \(f.id.padding(toLength: 18, withPad: " ", startingAt: 0)) GT_visible=\(f.category.shouldBeVisible)  stddev=\(String(format: "%.1f", sd))")
    }
    let croppedVerdict = Dictionary(uniqueKeysWithValues:
        trials.filter { $0.arm == "cropped" }.map { ($0.fixtureID, $0.verdictVisible) })
    let gateReport = buildGateReport(fixtures: fixtures, ink: ink, croppedVerdict: croppedVerdict)
    print("\n" + gateReport)

    let geoReport = buildGeoReport()
    print("\n" + geoReport)

    let report = buildReport(trials: trials) + "\n" + gateReport + "\n" + geoReport
    print("\n" + report)
    try? report.write(toFile: (outDir as NSString).appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    writeJSON(trials: trials, to: (outDir as NSString).appendingPathComponent("results.json"))
    print("\n出力: \(outDir)")
}

// MARK: - 集計・レポート

func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.0f%%", Double(n) / Double(d) * 100) }

func latencyStats(_ xs: [Int]) -> (min: Int, median: Int, p90: Int, max: Int, mean: Int) {
    guard !xs.isEmpty else { return (0, 0, 0, 0, 0) }
    let s = xs.sorted()
    let median = s[s.count / 2]
    let p90 = s[min(s.count - 1, Int(Double(s.count) * 0.9))]
    return (s.first!, median, p90, s.last!, xs.reduce(0, +) / xs.count)
}

func buildReport(trials: [Trial]) -> String {
    var out = "# FM occlusion-guard PoC 計測結果\n\n"
    for arm in ["cropped", "full"] {
        let ts = trials.filter { $0.arm == arm }
        let decided = ts.filter { $0.verdictVisible != nil }
        let undecided = ts.count - decided.count
        // 二値: verdict.visible が GT と一致したか
        let correct = decided.filter { $0.verdictVisible == $0.groundTruthVisible }.count
        // 偽陽性排除(本命): GT=見えない を verdict=見えない と正しく弾けたか
        let occluded = decided.filter { !$0.groundTruthVisible }
        let occludedCaught = occluded.filter { $0.verdictVisible == false }.count
        // 誤反転(有害): GT=見える を verdict=見えない と却下したか
        let visibleCases = decided.filter { $0.groundTruthVisible }
        let harmfulFlips = visibleCases.filter { $0.verdictVisible == false }.count
        let lat = latencyStats(ts.map { $0.latencyMs })

        out += "## アーム: \(arm)\n\n"
        out += "- 総試行: \(ts.count)(判定不能 \(undecided))\n"
        out += "- 全体正解率: \(correct)/\(decided.count)(\(pct(correct, decided.count)))\n"
        out += "- **偽陽性排除の再現率**(隠れを弾けた割合): \(occludedCaught)/\(occluded.count)(\(pct(occludedCaught, occluded.count)))\n"
        out += "- **有害な誤反転率**(正しい要素を却下): \(harmfulFlips)/\(visibleCases.count)(\(pct(harmfulFlips, visibleCases.count)))\n"
        out += "- レイテンシ ms: min=\(lat.min) median=\(lat.median) p90=\(lat.p90) max=\(lat.max) mean=\(lat.mean)\n\n"
        out += "| カテゴリ | 期待visible | 判定visible正解 | 主な state |\n|---|---|---|---|\n"
        for cat in Category.allCases {
            let cts = decided.filter { $0.category == cat }
            let ok = cts.filter { $0.verdictVisible == $0.groundTruthVisible }.count
            let states = Dictionary(grouping: cts, by: { $0.state }).mapValues { $0.count }
                .sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            out += "| \(cat.rawValue) | \(cat.shouldBeVisible) | \(ok)/\(cts.count) | \(states) |\n"
        }
        out += "\n"
    }
    out += "> 二値判定 = FM の visible が正解ラベルと一致したか。偽陽性排除の再現率が高く、有害な誤反転率が低いほど実用的。\n"
    return out
}

// 事前フィルタで FM をゲートした場合の、FM 削減率と正確性維持を閾値スイープで評価する。
func buildGateReport(fixtures: [Fixture], ink: [String: Double],
                     croppedVerdict: [String: Bool?]) -> String {
    var out = "## 事前フィルタ(Tier 1: ピクセル分散)によるFMゲート\n\n"
    out += "ゲート: stddev >= 閾値 → 見えているとみなし **FM 省略**(pass) / stddev < 閾値 → **FM(cropped)** で確定。\n\n"
    out += "| 閾値 | FM呼出 | FM削減 | 生存偽陽性 | 有害誤反転 | 総合正解 |\n|---|---|---|---|---|---|\n"
    for thr in [6.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0] {
        var fmCalls = 0, correct = 0, survivingFP = 0, harmfulFlip = 0
        for f in fixtures {
            let sd = ink[f.id] ?? -1
            let gt = f.category.shouldBeVisible
            let finalVisible: Bool
            if sd >= thr {
                finalVisible = true            // FM 省略・見えているとみなす
            } else {
                fmCalls += 1
                // FM が判定不能(nil)なら従来どおり pass(素通り)
                finalVisible = (croppedVerdict[f.id] ?? nil) ?? true
            }
            if finalVisible == gt { correct += 1 }
            if !gt && finalVisible { survivingFP += 1 }   // 隠れなのに pass のまま=偽陽性残存
            if gt && !finalVisible { harmfulFlip += 1 }   // 見えているのに却下
        }
        out += "| \(Int(thr)) | \(fmCalls)/\(fixtures.count) | \(pct(fixtures.count - fmCalls, fixtures.count)) | \(survivingFP) | \(harmfulFlip) | \(pct(correct, fixtures.count)) |\n"
    }
    out += "\n> 全件 FM(ゲート無し)= 呼出 \(fixtures.count)/\(fixtures.count)・偽陽性排除100%。ゲートは FM 呼出を減らしつつ生存偽陽性・有害誤反転を増やさない閾値を選ぶ。\n"
    return out
}

// Tier-0 幾何ヒューリスティック([OcclusionSuspicion])の単体確認。画像フィクスチャには
// ツリーが無いため、合成スナップショットで「疑いを正しく発火/非発火するか」を検査する。
func buildGeoReport() -> String {
    func elem(_ ref: Int, _ f: FTRect, depth: Int = 0, label: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "StaticText", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: f, depth: depth)
    }
    let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    let target = elem(1, FTRect(x: 40, y: 430, width: 322, height: 30), label: "残高 ¥12,500")

    struct Case { let name: String; let elements: [ElementInfo]; let loose: Bool; let expect: Bool }
    let cases: [Case] = [
        // 対象のみ=無罪
        .init(name: "単独(覆いなし)", elements: [target], loose: false, expect: false),
        // 後(手前)に載る大きな覆い要素=疑い
        .init(name: "手前に覆い要素", elements: [target,
              elem(2, FTRect(x: 30, y: 425, width: 342, height: 40))], loose: false, expect: true),
        // 対象より前(背面)にしか要素が無い=無罪
        .init(name: "背面のみ(順序前)", elements: [
              elem(2, FTRect(x: 30, y: 425, width: 342, height: 40)), target], loose: false, expect: false),
        // 画面外へはみ出す(切れ)=疑い
        .init(name: "画面外はみ出し", elements: [
              elem(1, FTRect(x: 40, y: 860, width: 322, height: 40), label: "x")], loose: false, expect: true),
        // 部分一致で解決=疑い
        .init(name: "部分一致解決", elements: [target], loose: true, expect: true),
    ]

    var out = "## Tier-0 幾何ヒューリスティック(ツリーのみ)単体確認\n\n"
    out += "| ケース | 期待 | 結果 |\n|---|---|---|\n"
    var pass = 0
    for c in cases {
        let tgt = c.elements.first { $0.ref == 1 } ?? target
        let got = OcclusionSuspicion.geometric(element: tgt, in: c.elements, screen: screen, looseMatch: c.loose)
        let ok = got == c.expect
        if ok { pass += 1 }
        out += "| \(c.name) | \(c.expect) | \(got) \(ok ? "✓" : "✗") |\n"
    }
    out += "\n判定一致: \(pass)/\(cases.count)。覆う要素がツリーに載る部分覆いは Tier-0 で拾い、ピクセルが高インクでも FM に回せる。\n"
    return out
}

func writeJSON(trials: [Trial], to path: String) {
    let arr = trials.map { t -> [String: Any] in
        ["fixtureID": t.fixtureID, "category": t.category.rawValue, "arm": t.arm,
         "groundTruthVisible": t.groundTruthVisible,
         "verdictVisible": t.verdictVisible as Any, "state": t.state,
         "reason": t.reason, "latencyMs": t.latencyMs]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "live" {
    await liveMode()
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "dump" {
    await dumpMode()
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "explore" {
    await exploreMode()
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "occtest" {
    await occTestMode()
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "e2e" {
    await e2eMode()
} else {
    await run()
}
