// occlusion-guard(FM 視覚照合)の判定を、保存済みの crop に対して再現・再判定する単体ツール。
// Apple へ不具合報告する際の最小再現コードも兼ねる(ftester に依存せず FoundationModels だけを使う)。
//
// 使い道: 実行中に guard が反転すると OcclusionVerifier が FM へ渡した crop を
//   ~/Library/Logs/ftester/occlusion/occlusion-<時刻>.png (+ .txt = 期待テキスト)
// に保存する。それをこのツールに食わせて、同じ instructions / prompt / @Generable 型 /
// GenerationOptions(greedy) で何度も再判定し、誤判定が決定的か揺らぎかを切り分ける。
//
// **レポートに添付される失敗時スクリーンショットは FM の入力ではない**(poll が尽きた後の別撮り)。
// 切り分けには必ず上記のダンプを使うこと(2026-07-23、これを取り違えて誤った結論を出した)。
//
// ビルド: xcrun swiftc -O Scripts/occlusion-repro.swift -o /tmp/occlusion-repro
// 実行:   /tmp/occlusion-repro <png> [回数] [期待テキスト]
//         /tmp/occlusion-repro <png> --crop x,y,w,h [回数] [期待テキスト]
//         期待テキスト省略時は <png> と同名の .txt を読む。
//
// 実装は Sources/FTAgent/OcclusionVerifier.swift と一致させること(instructions / prompt /
// VisibilityVerdict / sampling)。片方だけ変えると再現性の比較が成立しなくなる。

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
    @Guide(description: "期待テキストが覆われず・切れず・減光されず明瞭に読めるなら true。少しでも隠れ/欠け/判読困難があれば false")
    var visible: Bool

    @Guide(description: "見え方の分類")
    var state: VisibilityState

    @Guide(description: "実際に読み取れた文字列。読めなければ空文字")
    var observedText: String

    @Guide(description: "判定理由(日本語で1文)")
    var reason: String
}

let instructions = """
あなたは UI テストの視覚検証者です。渡される画像は、ある UI 要素の周辺だけを切り出したものです。
目的は「その要素が別の要素・オーバーレイ・ローディング表示・減光レイヤーに覆われて見えないか」
(occlusion)だけを見抜くことです。次を厳守してください:
- テキストは末尾が「…」で省略されたり、途中で折り返し(改行)されることがあります。
  省略・折り返しは正常であり visible=true とします。期待テキストの先頭部分が読めれば十分です。
- visible=false にするのは次の場合だけ: (a)領域が別の不透明要素/オーバーレイに覆われている、
  (b)真っ白/真っ黒/単色で文字が全く無い、(c)期待テキストとは無関係の別文字列だけが描かれている。
- 多少の減光でも判読できるなら visible=true。推測で補完しないこと。
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
    fail("usage: occlusion-repro <png> [--crop x,y,w,h] [回数] [期待テキスト]")
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
let iterations = argv.first.flatMap { Int($0) } ?? 10
if !argv.isEmpty { argv.removeFirst() }
let pngURL = URL(fileURLWithPath: pngPath)
// 期待テキストはダンプの隣に置かれる .txt が既定(ftester が一緒に書き出す)
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

print("画像: \(pngPath) (\(image.width)x\(image.height))\(cropRect.map { " crop=\($0)" } ?? "")")
print("期待テキスト: \"\(expectedText)\" / 試行: \(iterations) 回(sampling: greedy)")
print("")

var counts: [String: Int] = [:]
var errors = 0
for i in 1...iterations {
    // ftester と同じく 1 呼び出し = 1 セッション(会話履歴を持ち回さない)
    let session = LanguageModelSession(instructions: instructions)
    do {
        let verdict = try await session.respond(
            generating: VisibilityVerdict.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
        ) {
            "期待テキスト(末尾は省略や折り返しがあり得る): \"\(expectedText)\"\nこのテキスト(またはその先頭部分)が、覆われず判読できる状態で描画されていますか。"
            Attachment(image)
        }.content
        let name = stateName(verdict.state)
        counts[name, default: 0] += 1
        print("\(verdict.visible ? "✅" : "❌") \(i): visible=\(verdict.visible) state=\(name) observed=\"\(verdict.observedText)\" reason=\(verdict.reason)")
    } catch {
        errors += 1
        print("⚠️ \(i): FM 呼び出し失敗: \(error)")
    }
}

print("")
print("集計: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " / "))  エラー=\(errors)")
