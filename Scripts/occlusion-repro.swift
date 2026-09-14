// occlusion-guard(FM 視覚照合)の判定を、保存済みの crop に対して再現・再判定する単体ツール。
// Apple へ不具合報告する際の最小再現コードも兼ねる(fleetest に依存せず FoundationModels だけを使う)。
//
// 使い道: 実行中に guard が反転すると OcclusionVerifier が FM へ渡した crop を
//   ~/Library/Logs/fleetest/occlusion/occlusion-<時刻>.png (+ .txt = 期待テキスト)
// に保存する。それをこのツールに食わせて、同じ instructions / prompt / @Generable 型 /
// GenerationOptions(greedy) で何度も転写させ、誤判定が決定的か揺らぎかを切り分ける。
//
// **レポートに添付される失敗時スクリーンショットは FM の入力ではない**(poll が尽きた後の別撮り)。
// 切り分けには必ず上記のダンプを使うこと(2026-07-23、これを取り違えて誤った結論を出した)。
//
// ビルド: xcrun swiftc -O Scripts/occlusion-repro.swift -o /tmp/occlusion-repro
//         (画像添付は macOS 27+ の API。macOS 26 ではコンパイルできない = occlusion 自体が無効)
// 実行:   /tmp/occlusion-repro <png> [回数] [期待テキスト]
//         /tmp/occlusion-repro <png> --crop x,y,w,h [回数] [期待テキスト]
//         /tmp/occlusion-repro <png> --scale 2 ...(production が等倍で読めなかったときに撃つ拡大側)
//         期待テキスト省略時は <png> と同名の .txt を読む。
//
// 実装は Sources/FTFoundationModels/OcclusionVerifier.swift と一致させること(instructions / prompt /
// @Generable の欄と @Guide の文言 / sampling / 出力上限)。片方だけ変えると再現性の比較が成立しなくなる
// (実際に production が英語化された後もこのツールが日本語のままズレていた。2026-09-03 に同期)。
// **同期は OcclusionReproSyncTests がソース走査で守る**。
//
// production は FM に期待文字列を渡さず転写だけを求め、可否はホスト(FTCore.TranscriptMatch)が
// 期待文字列と突き合わせて決める。このツールは転写を並べるところまで —— 可否の規則は fleetest の
// 単体テスト(TranscriptMatchTests)側で見る。

import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

@Generable
struct DrawnTextTranscript {
    @Guide(description: "Every character of text drawn in the image, transcribed exactly as written, in reading order; empty when the image contains no legible text")
    var text: String
}

let instructions = """
You read text in screenshots of mobile apps for automated tests. The image is a crop around
one UI element. Transcribe only the text that is actually drawn, exactly as written, in reading
order. Never guess, complete or translate. If the area is blank, a solid colour, or covered by
an opaque layer with no text, return an empty transcript.
"""

// プロンプト本文(OcclusionVerifier.prompt と同文。期待文字列は入れない)
let userPrompt = "What text is drawn in this image?"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func enlarged(_ image: CGImage, by factor: Int) -> CGImage {
    guard factor > 1 else { return image }
    let width = image.width * factor, height = image.height * factor
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage() ?? image
}

var argv = Array(CommandLine.arguments.dropFirst())
guard let pngPath = argv.first else {
    fail("usage: occlusion-repro <png> [--crop x,y,w,h] [--scale n] [回数] [期待テキスト]")
}
argv.removeFirst()

var cropRect: CGRect?
var scale = 1
while let flag = argv.first, flag.hasPrefix("--") {
    argv.removeFirst()
    switch flag {
    case "--crop":
        let parts = (argv.first ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { fail("--crop は x,y,w,h の4値") }
        cropRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        argv.removeFirst()
    case "--scale":
        guard let n = argv.first.flatMap({ Int($0) }), n >= 1 else { fail("--scale は 1 以上の整数") }
        scale = n
        argv.removeFirst()
    default:
        fail("不明なオプション: \(flag)")
    }
}
let iterations = argv.first.flatMap { Int($0) } ?? 10
if !argv.isEmpty { argv.removeFirst() }
let pngURL = URL(fileURLWithPath: pngPath)
// 期待テキストはダンプの隣に置かれる .txt が既定(fleetest が一緒に書き出す)
let sidecar = try? String(contentsOf: pngURL.deletingPathExtension().appendingPathExtension("txt"),
                          encoding: .utf8)
let expectedText = argv.first ?? sidecar ?? "(期待テキスト無し)"

guard let data = FileManager.default.contents(atPath: pngPath),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("画像を読めません: \(pngPath)")
}
let image = enlarged(cropRect.flatMap { full.cropping(to: $0) } ?? full, by: scale)

print("画像: \(pngPath) (\(image.width)x\(image.height))\(cropRect.map { " crop=\($0)" } ?? "") scale=\(scale)")
print("期待テキスト: \"\(expectedText)\" / 試行: \(iterations) 回(sampling: greedy)")
print("")

var counts: [String: Int] = [:]
var errors = 0
for i in 1...iterations {
    // fleetest と同じく 1 呼び出し = 1 セッション(会話履歴を持ち回さない)
    do {
        let transcript = try await LanguageModelSession(instructions: instructions).respond(
            generating: DrawnTextTranscript.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120)
        ) {
            userPrompt
            Attachment(image)
        }.content
        counts[transcript.text, default: 0] += 1
        print("\(i) transcript=\"\(transcript.text)\"")
    } catch {
        errors += 1
        print("⚠️ \(i) FM 呼び出し失敗: \(error)")
    }
}

print("")
print("集計: \(counts.sorted { $0.value > $1.value }.map { "\"\($0.key)\"=\($0.value)" }.joined(separator: " / "))  エラー=\(errors)")
