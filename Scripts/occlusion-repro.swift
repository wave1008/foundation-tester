// occlusion-guard(FM 視覚照合)の判定を、保存済みの crop に対して再現・再判定する単体ツール。
// Apple へ不具合報告する際の最小再現コードも兼ねる(fleetest に依存せず FoundationModels だけを使う)。
//
// 使い道: 実行中に guard が反転すると OcclusionVerifier が FM へ渡した crop を
//   ~/Library/Logs/fleetest/occlusion/occlusion-<時刻>.png (+ .txt = 期待テキスト)
// に保存する。それをこのツールに食わせて、同じ instructions / prompt / @Generable 型 /
// GenerationOptions(greedy) で何度も再判定し、誤判定が決定的か揺らぎかを切り分ける。
//
// **レポートに添付される失敗時スクリーンショットは FM の入力ではない**(poll が尽きた後の別撮り)。
// 切り分けには必ず上記のダンプを使うこと(2026-07-23、これを取り違えて誤った結論を出した)。
//
// ビルド: xcrun swiftc -O Scripts/occlusion-repro.swift -o /tmp/occlusion-repro
//         (画像添付は macOS 27+ の API。macOS 26 ではコンパイルできない = occlusion 自体が無効)
// 実行:   /tmp/occlusion-repro <png> [回数] [期待テキスト]
//         /tmp/occlusion-repro <png> --crop x,y,w,h [回数] [期待テキスト]
//         期待テキスト省略時は <png> と同名の .txt を読む。
//
// 実装は Sources/FTFoundationModels/OcclusionVerifier.swift と一致させること(instructions / prompt /
// @Generable の欄と @Guide の文言 / sampling)。片方だけ変えると再現性の比較が成立しなくなる
// (実際に production が英語化された後もこのツールが日本語のままズレていた。2026-09-03 に同期)。
// **同期は OcclusionReproSyncTests がソース走査で守る**。
//
// production は**2段構え**なので、このツールも同じ順で撃つ: 1段目は reason を作らせない選別
// (3欄・80tok)、1段目が「見えていない」と答えた回だけ2段目(従来の4欄・200tok)。
// 1段目だけ・2段目だけを見たいときは --stage screening / --stage detail。

import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

@Generable
enum VisibilityState {
    case fullyVisible
    case covered
    case dimmed
    case notRendered
    case textMismatch
}

@Generable
struct VisibilityVerdict {
    @Guide(description: "true when the expected text is clearly readable — not covered, not cut off, not dimmed. false on any occlusion, clipping or illegibility")
    var visible: Bool

    @Guide(description: "Classification of how it appears")
    var state: VisibilityState

    @Guide(description: "The text actually read; empty when unreadable")
    var observedText: String

    @Guide(description: "Reason for the verdict, in one English sentence")
    var reason: String
}

/// 1段目(選別)。**reason だけを落とした3欄**。observedText を落とすと判定が壊れる
/// (実データで反転を 106/147 取りこぼす。docs/performance-tuning.md §3.5.1)
@Generable
struct VisibilityScreening {
    @Guide(description: "true when the expected text is clearly readable — not covered, not cut off, not dimmed. false on any occlusion, clipping or illegibility")
    var visible: Bool

    @Guide(description: "Classification of how it appears")
    var state: VisibilityState

    @Guide(description: "The text actually read; empty when unreadable")
    var observedText: String
}

let instructions = """
You visually verify UI tests. The image you receive is a crop around one UI element.
Your only job is to detect occlusion: whether the element is hidden behind another
element, an overlay, a loading indicator or a dimming layer. Follow these rules strictly:
- Text may be truncated with an ellipsis or wrapped onto multiple lines. Truncation and
  wrapping are normal — return visible=true. Reading the beginning of the expected text is enough.
- Return visible=false ONLY when: (a) the area is covered by another opaque element/overlay,
  (b) it is blank/black/solid-colour with no text at all, or (c) only unrelated text is drawn.
- Slight dimming is visible=true as long as the text is legible. Never fill gaps by guessing.
"""

func stateName(_ s: VisibilityState) -> String {
    switch s {
    case .fullyVisible: return "fullyVisible"
    case .covered: return "covered"
    case .dimmed: return "dimmed"
    case .notRendered: return "notRendered"
    case .textMismatch: return "textMismatch"
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var argv = Array(CommandLine.arguments.dropFirst())
guard let pngPath = argv.first else {
    fail("usage: occlusion-repro <png> [--crop x,y,w,h] [--stage both|screening|detail] [回数] [期待テキスト]")
}
argv.removeFirst()

var cropRect: CGRect?
if argv.first == "--crop" {
    argv.removeFirst()
    let parts = (argv.first ?? "").split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { fail("--crop は x,y,w,h の4値") }
    cropRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    argv.removeFirst()
}
// 既定は production と同じ2段構え。片方だけを繰り返し見たいときに絞る
var stage = "both"
if argv.first == "--stage" {
    argv.removeFirst()
    guard let s = argv.first, ["both", "screening", "detail"].contains(s) else {
        fail("--stage は both / screening / detail")
    }
    stage = s
    argv.removeFirst()
}
let iterations = argv.first.flatMap { Int($0) } ?? 10
if !argv.isEmpty { argv.removeFirst() }
let pngURL = URL(fileURLWithPath: pngPath)
// 期待テキストはダンプの隣に置かれる .txt が既定(fleetest が一緒に書き出す)
let sidecar = try? String(contentsOf: pngURL.deletingPathExtension().appendingPathExtension("txt"),
                          encoding: .utf8)
guard let expectedText = argv.first ?? sidecar else {
    fail("期待テキストを指定するか、<png> と同名の .txt を置いてください")
}

guard let data = FileManager.default.contents(atPath: pngPath),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("画像を読めません: \(pngPath)")
}
let image = cropRect.flatMap { full.cropping(to: $0) } ?? full

// プロンプト本文(OcclusionVerifier.verifyCropped と同文)
let userPrompt = "Expected text (may be truncated or wrapped at the end): \"\(expectedText)\"\nIs this text (or its beginning) drawn unoccluded and legible?"

print("画像: \(pngPath) (\(image.width)x\(image.height))\(cropRect.map { " crop=\($0)" } ?? "")")
print("期待テキスト: \"\(expectedText)\" / 試行: \(iterations) 回(sampling: greedy) / 段: \(stage)")
print("")

var counts: [String: Int] = [:]
var errors = 0
var detailCalls = 0
for i in 1...iterations {
    // fleetest と同じく 1 呼び出し = 1 セッション(会話履歴を持ち回さない)
    var screeningSaidVisible = false
    if stage != "detail" {
        do {
            let s = try await LanguageModelSession(instructions: instructions).respond(
                generating: VisibilityScreening.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 80)
            ) {
                userPrompt
                Attachment(image)
            }.content
            screeningSaidVisible = s.visible
            let name = stateName(s.state)
            counts["1段:" + name, default: 0] += 1
            print("\(s.visible ? "✅" : "❌") \(i) 1段: visible=\(s.visible) state=\(name) observed=\"\(s.observedText)\"")
        } catch {
            errors += 1
            print("⚠️ \(i) 1段: FM 呼び出し失敗: \(error)")
            continue   // production も1段目が失敗したら nil を返して2段目へ行かない
        }
    }
    // production が2段目を撃つのは「1段目が見えていないと言った回」だけ
    guard stage != "screening", screeningSaidVisible == false || stage == "detail" else { continue }
    detailCalls += 1
    do {
        let verdict = try await LanguageModelSession(instructions: instructions).respond(
            generating: VisibilityVerdict.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
        ) {
            userPrompt
            Attachment(image)
        }.content
        let name = stateName(verdict.state)
        counts["2段:" + name, default: 0] += 1
        print("\(verdict.visible ? "✅" : "❌") \(i) 2段: visible=\(verdict.visible) state=\(name) observed=\"\(verdict.observedText)\" reason=\(verdict.reason)")
    } catch {
        errors += 1
        print("⚠️ \(i) 2段: FM 呼び出し失敗: \(error)")
    }
}

print("")
print("集計: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " / "))"
    + "  2段目に落ちた回=\(detailCalls)  エラー=\(errors)")
