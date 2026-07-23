// FoundationModels の間欠死(availability は available のまま実呼び出しだけ失敗する)を
// 追跡する常駐プローブ。Apple への不具合報告に必要な「遷移時刻・頻度・text/vision どちらが
// 死ぬか」を記録する(2026-07-23 に SensitiveContentAnalysisML error 15 の生→死→生→死を
// 同日中に観測したが、遷移時刻の記録が無く報告できなかった)。
//
// text と vision(画像添付)を**別々に**プローブする理由: occlusion 偽陽性(Projects/E2E-Flutter/
// README.md の既知事象)の有力仮説が「SCA 劣化の過程で画像添付だけが先に壊れる」であり、
// vision だけ先に死ぬ観測が取れれば2つの事象が同じ根で繋がる。
//
// ビルド: xcrun swiftc -O Scripts/fm-flap-monitor.swift -o /tmp/fm-flap-monitor
// 実行:   /tmp/fm-flap-monitor [間隔秒=60] >> ~/Library/Logs/ftester/fm-flap.ndjson
//         1行 = 1プローブ結果(NDJSON)。state が変わった行には "transition": true が付き、
//         直近 120 秒の modelmanagerd / SensitiveContentAnalysis 関連の system log を
//         ~/Library/Logs/ftester/fm-transition-<時刻>.log に保存する。

import CoreGraphics
import Foundation
import FoundationModels

@Generable
struct ColorAnswer {
    @Guide(description: "画像の大部分を占める色の名前(日本語で1語)")
    var color: String
}

@Generable
struct EchoAnswer {
    @Guide(description: "指示された単語そのもの")
    var word: String
}

func nowISO() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func makeRedImage() -> CGImage {
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return ctx.makeImage()!
}

struct ProbeResult {
    let ok: Bool
    let ms: Int
    let detail: String   // ok: 応答内容 / ng: エラー1行
}

// text プローブ: 画像を介さない最小呼び出し
func probeText() async -> ProbeResult {
    let start = Date()
    let session = LanguageModelSession(instructions: "指示された単語をそのまま返してください。")
    do {
        let r = try await session.respond(
            generating: EchoAnswer.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 30)
        ) { "単語: りんご" }.content
        return ProbeResult(ok: true, ms: Int(Date().timeIntervalSince(start) * 1000),
                           detail: r.word)
    } catch {
        return ProbeResult(ok: false, ms: Int(Date().timeIntervalSince(start) * 1000),
                           detail: String("\(error)".prefix(300)))
    }
}

// vision プローブ: 64x64 の赤一色画像。SCA(画像前処理)経路を必ず通る
func probeVision(image: CGImage) async -> ProbeResult {
    let start = Date()
    let session = LanguageModelSession(instructions: "画像の色を答えてください。")
    do {
        let r = try await session.respond(
            generating: ColorAnswer.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 30)
        ) {
            "この画像の大部分を占める色は何色ですか。"
            Attachment(image)
        }.content
        return ProbeResult(ok: true, ms: Int(Date().timeIntervalSince(start) * 1000),
                           detail: r.color)
    } catch {
        return ProbeResult(ok: false, ms: Int(Date().timeIntervalSince(start) * 1000),
                           detail: String("\(error)".prefix(300)))
    }
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r", "\t": out += " "
        default:
            if c.value < 0x20 { out += " " } else { out.unicodeScalars.append(c) }
        }
    }
    return out
}

/// 遷移時に直近の system log を保存(modelmanagerd / SCA / FoundationModels 関連)。
/// FB 報告の「遷移直前に何が起きたか」の材料。失敗しても監視は続ける。
func dumpSystemLog(tag: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ftester")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("fm-transition-\(tag).log")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["show", "--last", "120s", "--style", "compact", "--predicate",
                   "process CONTAINS[c] 'modelmanager' OR process CONTAINS[c] 'sensitivecontent' "
                   + "OR subsystem CONTAINS[c] 'FoundationModels' OR subsystem CONTAINS[c] 'SensitiveContent' "
                   + "OR subsystem CONTAINS[c] 'modelmanager'"]
    p.standardOutput = try? FileHandle(forWritingTo: out)
    if (try? out.checkResourceIsReachable()) != true {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: out)
    }
    try? p.run()
    p.waitUntilExit()
}

let interval = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 60) : 60
let redImage = makeRedImage()
var lastState: String?

// 標準出力は行バッファでないことがある(リダイレクト時)ため、1行ごとに明示 flush する
setvbuf(stdout, nil, _IONBF, 0)

while true {
    let text = await probeText()
    let vision = await probeVision(image: redImage)
    let state = "\(text.ok ? "T" : "t")\(vision.ok ? "V" : "v")"   // 例 TV=両方生存, Tv=vision だけ死
    let transition = lastState != nil && state != lastState
    let line = "{\"at\":\"\(nowISO())\",\"state\":\"\(state)\""
        + ",\"text\":{\"ok\":\(text.ok),\"ms\":\(text.ms),\"detail\":\"\(jsonEscape(text.detail))\"}"
        + ",\"vision\":{\"ok\":\(vision.ok),\"ms\":\(vision.ms),\"detail\":\"\(jsonEscape(vision.detail))\"}"
        + (transition ? ",\"transition\":true,\"from\":\"\(lastState!)\"" : "")
        + "}"
    print(line)
    if transition {
        dumpSystemLog(tag: nowISO().replacingOccurrences(of: ":", with: "-"))
    }
    lastState = state
    try? await Task.sleep(for: .seconds(interval))
}
