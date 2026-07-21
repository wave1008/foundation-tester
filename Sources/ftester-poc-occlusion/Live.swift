// [PoC occlusion-guard] 実機(シミュレータ)再計測モード。
// 空きデバイスに inapp ブリッジを注入起動し、実アプリのスナップショット+スクショに
// OcclusionVerifier をかけて、合成フィクスチャで得た「可視は素通り/隠れは検知」が実描画でも成り立つか、
// および実機レイテンシを測る。占有中デバイスに触れないよう udid を明示指定する(MCP 不使用)。
//
// 使い方: ftester-poc-occlusion live <udid> <bundleID> <port> <出力ディレクトリ>

import AppKit
import Foundation
import FTAgent
import FTBridgeClient
import FTCore

struct LiveElementResult {
    let screen: String
    let ref: Int
    let type: String
    let text: String
    let frame: FTRect
    let inkStdDev: Double
    let verdictVisible: Bool?
    let state: String
    let reason: String
    let latencyMs: Int
}

// FM を使わず、対象アプリの全要素(ref/type/label/frame/eligible)をダンプする。
// 足切りフィルタ([OcclusionEligibility])が実 UI の型に合っているか検証するための下見。
func dumpMode() async {
    let a = CommandLine.arguments
    guard a.count >= 5 else { print("usage: dump <udid> <bundleID> <port>"); exit(2) }
    guard let port = UInt16(a[4]) else { print("bad port"); exit(2) }
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let driver = InAppDriver(repoRoot: repoRoot, udid: a[2], port: port)
    do { try await driver.launch(bundleID: a[3]) } catch { print("launch 失敗: \(error)"); exit(1) }
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    guard let snap = try? await driver.snapshot() else { print("snapshot 失敗"); exit(1) }
    print("screen \(Int(snap.screen.width))x\(Int(snap.screen.height)) / \(snap.elements.count) 要素\n")
    print("elig | type | label | frame")
    for e in snap.elements where (e.label?.isEmpty == false) {
        let el = OcclusionEligibility.eligible(type: e.type, label: e.label ?? "")
        let mark = el.ok ? "○" : "×(\(el.reason))"
        print("\(mark) | \(e.type) | \"\((e.label ?? "").prefix(30))\" | \(Int(e.frame.x)),\(Int(e.frame.y)) \(Int(e.frame.width))x\(Int(e.frame.height))")
    }
    try? await driver.terminate()
}

// 画面遷移の下見。launch 後、引数のラベル部分文字列/id を順にタップし各段階でスクショ保存。
// オーバーレイ(モーダル/シート/スナックバー)を出せる導線を目視で探すため。
// 使い方: explore <udid> <bundleID> <port> <outDir> [tapLabel1] [tapLabel2] ...
func exploreMode() async {
    let a = CommandLine.arguments
    guard a.count >= 6 else { print("usage: explore <udid> <bundle> <port> <outDir> [tap...]"); exit(2) }
    guard let port = UInt16(a[4]) else { print("bad port"); exit(2) }
    let outDir = a[5]
    let shots = (outDir as NSString).appendingPathComponent("shots")
    try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let driver = InAppDriver(repoRoot: repoRoot, udid: a[2], port: port)
    do { try await driver.launch(bundleID: a[3]) } catch { print("launch 失敗: \(error)"); exit(1) }
    try? await Task.sleep(nanoseconds: 2_500_000_000)

    func shot(_ name: String) async {
        if let s = try? await driver.screenshot() {
            try? s.write(to: URL(fileURLWithPath: (shots as NSString).appendingPathComponent("\(name).png")))
            print("  saved \(name).png")
        }
    }
    await shot("step0")
    let taps = Array(a.dropFirst(6))
    for (i, key) in taps.enumerated() {
        guard let snap = try? await driver.snapshot() else { break }
        // id 完全一致 → label 部分一致 の順で対象要素を探す
        let target = snap.elements.first { $0.identifier == key }
            ?? snap.elements.first { ($0.label?.contains(key) ?? false) }
        guard let t = target else { print("  '\(key)' 見つからず(中断)"); break }
        print("  tap[\(i+1)] '\(key)' → ref=\(t.ref) type=\(t.type) \"\(t.label ?? "")\"")
        try? await driver.tap(ref: t.ref)
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        await shot("step\(i+1)")
    }
    try? await driver.terminate()
    print("shots: \(shots)")
}

// 実 occlusion(true-positive)を作って検証: 商品詳細で「カートに追加」→ スナックバーが下部を覆う瞬間に
// snapshot+screenshot し、覆われた適格テキストを verifier が visible=false と当てられるか見る。
// 使い方: occtest <udid> <bundleID> <port> <outDir>
func occTestMode() async {
    let a = CommandLine.arguments
    guard a.count >= 6, let port = UInt16(a[4]) else { print("usage: occtest <udid> <bundle> <port> <outDir>"); exit(2) }
    let outDir = a[5]
    let shots = (outDir as NSString).appendingPathComponent("shots")
    try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let driver = InAppDriver(repoRoot: repoRoot, udid: a[2], port: port)
    guard FMDoctor.check().available else { print("FM 不可"); exit(1) }
    do { try await driver.launch(bundleID: a[3]) } catch { print("launch 失敗: \(error)"); exit(1) }
    try? await Task.sleep(nanoseconds: 2_500_000_000)

    // 商品詳細へ
    guard let s0 = try? await driver.snapshot(),
          let card = s0.elements.first(where: { $0.type == "Button" && ($0.label?.contains("腕時計") ?? false) }) else {
        print("商品カード見つからず"); try? await driver.terminate(); exit(1)
    }
    try? await driver.tap(ref: card.ref)
    try? await Task.sleep(nanoseconds: 1_800_000_000)

    // 追加前の下部適格テキストを記録(基準)
    guard let sBefore = try? await driver.snapshot(), let shotBefore = try? await driver.screenshot() else {
        print("詳細 snapshot 失敗"); try? await driver.terminate(); exit(1)
    }
    try? shotBefore.write(to: URL(fileURLWithPath: (shots as NSString).appendingPathComponent("detail-before.png")))
    let addBtn = sBefore.elements.first { ($0.label?.contains("カートに追加") ?? false) }
    guard let add = addBtn else { print("『カートに追加』見つからず"); try? await driver.terminate(); exit(1) }

    // カートに追加 → スナックバー出現直後に即キャプチャ(sleep 無し。tap は settle 済みで返る)
    try? await driver.tap(ref: add.ref)
    guard let sSnack = try? await driver.snapshot(), let shotSnack = try? await driver.screenshot() else {
        print("スナックバー snapshot 失敗"); try? await driver.terminate(); exit(1)
    }
    try? shotSnack.write(to: URL(fileURLWithPath: (shots as NSString).appendingPathComponent("snackbar.png")))

    let verifier = OcclusionVerifier()
    let clock = ContinuousClock()
    func verifyRegion(_ label: String, _ snap: SnapshotResponse, _ shot: Data) async {
        // 下部の適格テキストだけ(スナックバーが覆う領域)
        let pool = snap.elements.filter { ($0.label?.isEmpty == false)
            && $0.frame.y > snap.screen.height * 0.6
            && OcclusionEligibility.eligible(type: $0.type, label: $0.label ?? "").ok }
            .sorted { $0.frame.y < $1.frame.y }
        print("--- \(label): 下部適格テキスト \(pool.count) 件 ---")
        for e in pool {
            let sd = RegionInk.luminanceStdDev(pngData: shot, frame: e.frame, screen: snap.screen) ?? -1
            let start = clock.now
            let v = await verifier.verifyCropped(expectedText: e.label ?? "", frame: e.frame,
                                                 screen: snap.screen, screenshotPNG: shot)
            let ms = Int((clock.now - start) / .milliseconds(1))
            let mark = v.map { $0.visible ? "見え" : "隠れ" } ?? " ? "
            print("  [\(mark)] sd=\(String(format:"%.0f",sd)) \(ms)ms \"\(String((e.label ?? "").prefix(22)))\" (\(Int(e.frame.x)),\(Int(e.frame.y)) \(Int(e.frame.width))x\(Int(e.frame.height))) state=\(v?.state ?? "-")")
        }
    }
    print("\n=== 追加前(基準・全可視のはず) ===")
    await verifyRegion("detail-before", sBefore, shotBefore)
    print("\n=== スナックバー表示中(下部が覆われるはず) ===")
    await verifyRegion("snackbar", sSnack, shotSnack)
    print("\nshots: \(shots)")
    try? await driver.terminate()
}

// エンドツーエンド確認: 実ランナーと同一の StepExecutor + FMReplayDelegate(実 FM delegate)で
// exist / present の FlowStep を実機に対して実行し、覆われた要素で exist が失敗へ反転するか確認する。
// DSL exist() が生成するのと同じ FlowStep(occlusionGuard: true/false)を直接実行=ランタイム経路は同一。
// 使い方: e2e <udid> <bundleID> <port>
func e2eMode() async {
    let a = CommandLine.arguments
    guard a.count >= 5, let port = UInt16(a[4]) else { print("usage: e2e <udid> <bundle> <port>"); exit(2) }
    guard FMDoctor.check().available else { print("FM 不可"); exit(1) }
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let driver = InAppDriver(repoRoot: repoRoot, udid: a[2], port: port)
    do { try await driver.launch(bundleID: a[3]) } catch { print("launch 失敗: \(error)"); exit(1) }
    try? await Task.sleep(nanoseconds: 2_500_000_000)

    // 商品詳細へ(sticky「カートに追加」バー裏の「レビュー」= 実オクルージョン)
    guard let s0 = try? await driver.snapshot(),
          let card = s0.elements.first(where: { $0.type == "Button" && ($0.label?.contains("腕時計") ?? false) }) else {
        print("商品カード見つからず"); try? await driver.terminate(); exit(1)
    }
    try? await driver.tap(ref: card.ref)
    try? await Task.sleep(nanoseconds: 1_800_000_000)

    // 実ランナーと同じ構成
    let executor = StepExecutor(driver: driver, delegate: FMReplayDelegate())

    func run(_ title: String, _ step: FlowStep, expectPass: Bool) async {
        let outcome = await executor.execute(step)
        let passed: Bool
        switch outcome.status { case .passed, .passedViaFallback, .healed: passed = true; default: passed = false }
        let ok = passed == expectPass
        let statusText: String
        switch outcome.status {
        case .passed: statusText = "passed"
        case .passedViaFallback: statusText = "passedViaFallback"
        case .healed: statusText = "healed"
        case .failed(let m): statusText = "failed(\(m.prefix(80)))"
        case .skipped(let m): statusText = "skipped(\(m))"
        }
        print("\(ok ? "✓" : "✗ 期待外れ") \(title) → \(statusText)")
    }

    print("=== E2E: 実 StepExecutor + FMReplayDelegate ===")
    // 1) 覆われた要素を exist(既定ガード)→ 失敗へ反転するはず
    await run("exist(\"レビュー\")【sticky バー裏=覆い】期待:失敗",
              FlowStep(assert: "exists", locator: FlowLocator(label: "レビュー"),
                       timeout: 3, occlusionGuard: true), expectPass: false)
    // 2) 同じ要素を present(ガード無)→ ツリー存在で pass するはず
    await run("present(\"レビュー\")【ツリー存在のみ】期待:成功",
              FlowStep(assert: "exists", locator: FlowLocator(label: "レビュー"),
                       timeout: 3, occlusionGuard: false), expectPass: true)
    // 3) 可視テキストを exist(既定ガード)→ pass するはず(有害誤反転が無いこと)
    await run("exist(\"在庫あり\")【可視】期待:成功",
              FlowStep(assert: "exists", locator: FlowLocator(label: "在庫あり"),
                       timeout: 3, occlusionGuard: true), expectPass: true)

    try? await driver.terminate()
}

func liveMode() async {
    let a = CommandLine.arguments
    guard a.count >= 6 else {
        print("usage: ftester-poc-occlusion live <udid> <bundleID> <port> <outDir>"); exit(2)
    }
    let udid = a[2], bundleID = a[3]
    guard let port = UInt16(a[4]) else { print("bad port"); exit(2) }
    let outDir = a[5]
    let shotsDir = (outDir as NSString).appendingPathComponent("shots")
    try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)

    let doc = FMDoctor.check()
    print("FM: \(doc.detail)")
    guard doc.available else { print("FM 不可"); exit(1) }

    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let driver = InAppDriver(repoRoot: repoRoot, udid: udid, port: port)
    print("起動: \(bundleID) @ \(udid) port \(port)")
    do { try await driver.launch(bundleID: bundleID) } catch {
        print("launch 失敗: \(error.localizedDescription)"); exit(1)
    }
    // アプリの初期描画を待つ
    try? await Task.sleep(nanoseconds: 2_500_000_000)

    let verifier = OcclusionVerifier()
    let clock = ContinuousClock()
    var results: [LiveElementResult] = []

    // 1画面ぶんを処理: スクショ保存 → 各テキスト要素に検証器 → 結果集積
    func capture(_ label: String, maxElements: Int = 12, bottomOnly: Bool = false) async {
        let snap: SnapshotResponse
        let shot: Data
        do { snap = try await driver.snapshot(); shot = try await driver.screenshot() }
        catch { print("  [\(label)] snapshot/screenshot 失敗: \(error.localizedDescription)"); return }
        try? shot.write(to: URL(fileURLWithPath: (shotsDir as NSString).appendingPathComponent("\(label).png")))
        // 足切り済みの対象要素だけを検証(本番の occlusionFlip と同じ母集団)。
        var pool = snap.elements.filter { ($0.label?.isEmpty == false)
            && $0.frame.width >= 8 && $0.frame.height >= 8
            && OcclusionEligibility.eligible(type: $0.type, label: $0.label ?? "").ok }
        if bottomOnly { pool = pool.filter { $0.frame.y > snap.screen.height * 0.55 }
                              .sorted { $0.frame.y < $1.frame.y } }
        let texts = pool.prefix(maxElements)
        let excluded = snap.elements.filter { ($0.label?.isEmpty == false)
            && !OcclusionEligibility.eligible(type: $0.type, label: $0.label ?? "").ok }.count
        print("--- 画面 \(label): \(snap.elements.count) 要素中 適格テキスト \(texts.count) 件を検証(足切り除外 \(excluded) 件・screen \(Int(snap.screen.width))x\(Int(snap.screen.height))) ---")
        for e in texts {
            let text = e.label ?? ""
            let sd = RegionInk.luminanceStdDev(pngData: shot, frame: e.frame, screen: snap.screen) ?? -1
            let start = clock.now
            let v = await verifier.verifyCropped(expectedText: text, frame: e.frame,
                                                 screen: snap.screen, screenshotPNG: shot)
            let ms = Int((clock.now - start) / .milliseconds(1))
            results.append(LiveElementResult(screen: label, ref: e.ref, type: e.type, text: text,
                frame: e.frame, inkStdDev: sd, verdictVisible: v?.visible,
                state: v?.state ?? "nil", reason: v?.reason ?? "", latencyMs: ms))
            let vis = v?.visible.description ?? "nil"
            print("  [\(vis == "true" ? "見え" : (vis == "false" ? "隠れ" : "  ? "))] ref=\(e.ref) sd=\(String(format: "%.0f", sd)) \(ms)ms \"\(text.prefix(24))\" (\(Int(e.frame.x)),\(Int(e.frame.y)) \(Int(e.frame.width))x\(Int(e.frame.height))) state=\(v?.state ?? "-")")
        }
    }

    // 画面1: ランディング(実描画の可視テキスト → 有害誤反転とレイテンシを測る)
    await capture("01-landing")

    // 画面2: 下部タブバーの短いラベル群を素の状態で(キーボード前の基準・全て可視のはず)
    await capture("02-bottom-visible", bottomOnly: true)

    // 画面3: 検索フィールドをタップ→キーボードで下部タブバーを覆う(実 occlusion を作る)。
    // Compose は type が一定しないため label に「検索」を含む要素をタップ対象にする。
    if let snap = try? await driver.snapshot(),
       let field = snap.elements.first(where: { ($0.label?.contains("検索") ?? false)
           || $0.type.contains("TextField") || $0.type.contains("SearchField") }) {
        try? await driver.tap(ref: field.ref)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await capture("03-keyboard", bottomOnly: true)
    } else {
        print("(検索フィールド未検出: キーボード occlusion はスキップ)")
    }

    // レポート
    let md = liveReport(results)
    print("\n" + md)
    try? md.write(toFile: (outDir as NSString).appendingPathComponent("live-report.md"), atomically: true, encoding: .utf8)
    print("\nスクショ: \(shotsDir)")
    try? await driver.terminate()
}

func liveReport(_ rs: [LiveElementResult]) -> String {
    var out = "# 実機(シミュレータ)再計測: sut-ec-mobile\n\n"
    let lat = rs.compactMap { $0.verdictVisible != nil ? $0.latencyMs : nil }
    if !lat.isEmpty {
        let s = lat.sorted()
        out += "- 検証要素: \(rs.count)(判定不能 \(rs.filter { $0.verdictVisible == nil }.count))\n"
        out += "- レイテンシ ms: min=\(s.first!) median=\(s[s.count/2]) p90=\(s[min(s.count-1, Int(Double(s.count)*0.9))]) max=\(s.last!) mean=\(lat.reduce(0,+)/lat.count)\n\n"
    }
    out += "| 画面 | ref | visible | state | ink | ms | text | frame |\n|---|---|---|---|---|---|---|---|\n"
    for r in rs {
        out += "| \(r.screen) | \(r.ref) | \(r.verdictVisible.map(String.init(describing:)) ?? "nil") | \(r.state) | \(String(format:"%.0f",r.inkStdDev)) | \(r.latencyMs) | \(r.text.prefix(28)) | \(Int(r.frame.x)),\(Int(r.frame.y)) \(Int(r.frame.width))x\(Int(r.frame.height)) |\n"
    }
    out += "\n> ground truth はスクショ(shots/)目視で確定する。ランディング/タブは基本すべて可視=visible が全て true であるべき(false=有害誤反転)。キーボード画面は下部の覆われた要素が false であるべき。\n"
    return out
}
