// FM(Foundation Models)へ意図的に負荷をかけ、直列化の頭打ちを実測する(`fleetest doctor --fm-load`)。
//
// **FMGate を通さない**。FMGate は実行中の run が待ち行列で時間を捨てないための門であって、
// これを通すと測っているのが FM ではなく門になる。負荷生成器は意図的に素通しし、その代わり
// 実行中の run と FM の直列化容量を奪い合う(単独で回すこと。呼び出し側の doctor がヘルプに明記する)。
//
// **記録は FMHealth.record(kind:) を通す**(kind="loadtest")。FM 呼び出しの控えの書き手は
// ここ1箇所という規律(FMUsageLedger を直接呼ばない)。これにより負荷生成中の呼び出しも
// `~/.fleetest/fm-usage/<pid>.json` 経由で `api host-metrics` の fmCalls 行に載る
// (VSCode 拡張のツールバーの FM の行が動く副次効果)。

import CoreGraphics
import FTCore
import FoundationModels
import Foundation

public enum FMLoadGenerator {
    struct Sample {
        let ms: Double
        let ok: Bool
        let error: String?
    }

    public struct Summary {
        public let calls: Int
        public let failures: Int
        public let elapsedSeconds: Double
        public let throughputPerSecond: Double
        public let p50Ms: Int
        public let maxMs: Int
        public let firstError: String?
    }

    /// vision 負荷で使う最小の @Generable。判定精度は測らない(負荷生成が目的の唯一)ので、
    /// 出力トークンを切り詰められる最小の形にしてある(occlusion の VisibilityVerdict は流用しない —
    /// あちらはクロップ画像を要求するフィールドを持ち、単色プローブ画像とは目的が異なる)
    @Generable
    struct LoadVisionVerdict {
        @Guide(description: "true if the image is a single solid color")
        var solidColor: Bool
    }

    /// 指定の並列度で、指定の秒数が経過するまで FM を呼び続ける。
    /// **総数ではなく時間で止める**(締め切りを過ぎたら新しい呼び出しを投げない。投げ済みは待つ)。
    /// progress は呼び出しが1件終わるたびの累計件数(CLI の経過表示用。省略可)
    public static func run(seconds: Double, concurrency: Int, vision: Bool,
                           imageSize: (width: Int, height: Int)? = nil,
                            progress: (@Sendable (Int) -> Void)? = nil) async -> Summary {
        // 画像入力は macOS 27+(FMVisionSupport 参照)。使えない環境では黙って text へ落とさない ——
        // 落とすと「vision を頼んだのに text の結果が返ってきた」で何を測ったか分からなくなる
        if vision, !FMVisionSupport.isSupported {
            return Summary(calls: 0, failures: 0, elapsedSeconds: 0, throughputPerSecond: 0,
                           p50Ms: 0, maxMs: 0, firstError: FMVisionSupport.requirement)
        }

        let lanes = max(1, concurrency)
        let deadline = Date().addingTimeInterval(seconds)
        let started = Date()
        let counter = ProgressCounter()

        let samples: [Sample] = await withTaskGroup(of: [Sample].self) { group in
            for _ in 0..<lanes {
                group.addTask {
                    var mine: [Sample] = []
                    while Date() < deadline {
                        let sample = await Self.callOnce(vision: vision, imageSize: imageSize)
                        mine.append(sample)
                        if let progress {
                            let count = await counter.increment()
                            progress(count)
                        }
                    }
                    return mine
                }
            }
            var all: [Sample] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }

        return summarize(samples: samples, elapsedSeconds: Date().timeIntervalSince(started))
    }

    private static func callOnce(vision: Bool, imageSize: (width: Int, height: Int)?) async -> Sample {
        let startedAt = Date()
        do {
            if vision {
                // FMVisionSupport.isSupported gates the caller before any lane starts; this
                // #available is required by the compiler to touch Attachment, never expected to fail here.
                guard #available(macOS 27, *) else {
                    return Sample(ms: 0, ok: false, error: FMVisionSupport.requirement)
                }
                _ = try await LanguageModelSession().respond(
                    generating: LoadVisionVerdict.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
                ) {
                    "Is this image a single solid color?"
                    Attachment(imageSize.map { Self.makeImage(width: $0.width, height: $0.height) } ?? Self.probeImage)
                }.content
            } else {
                _ = try await LanguageModelSession().respond(
                    to: "Answer with just OK.",
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 8))
            }
            let ms = Self.elapsedMs(startedAt)
            FMHealth.record(kind: "loadtest", ms: ms, ok: true)
            return Sample(ms: ms, ok: true, error: nil)
        } catch {
            let ms = Self.elapsedMs(startedAt)
            let message = "loadtest: \(FMHealth.describe(error))"
            FMHealth.record(kind: "loadtest", ms: ms, ok: false, error: message)
            return Sample(ms: ms, ok: false, error: message)
        }
    }

    private static func elapsedMs(_ from: Date) -> Double { Date().timeIntervalSince(from) * 1000 }

    /// 単色 64x64 画像。判定精度は測らないので内容に意味は無い —— 生成コスト(推論の直列化待ち)だけが要る
    private static let probeImage: CGImage = makeImage(width: 64, height: 64)

    /// 指定寸法の単色画像。**寸法を振れることに意味がある** —— occlusion guard が実際に渡すのは
    /// スクリーンショットの切り出し(リサイズ無し。最大でスクショ全体 ≈1200x2600px)で、
    /// 合成の 64x64 とは推論コストが桁で違う。膝を測るときは本番の寸法で振ること
    static func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(max(1, width)), height: CGFloat(max(1, height))))
        // 単色だと圧縮も推論も極端に軽くなりうるので、格子を描いて情報量を持たせる
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        var y = 0
        while y < height { ctx.fill(CGRect(x: 0, y: y, width: width, height: 4)); y += 32 }
        var x = 0
        while x < width { ctx.fill(CGRect(x: x, y: 0, width: 4, height: height)); x += 32 }
        return ctx.makeImage()!
    }

    /// サンプル配列 → 集計の純粋関数(テスト対象)。空配列は calls=0 / p50=0 / max=0
    /// (vision 不可の早期 return と同型だが、firstError はここでは付けない —— 早期 return 側が
    /// FMVisionSupport.requirement を直接持つ。呼べたのに0件、という状態はここでは起きない)。
    /// p50 は線形補間なしの単純パーセンタイル(FMHealth.percentileMs と同じ規律。標本数が少ないため十分)
    static func summarize(samples: [Sample], elapsedSeconds: Double) -> Summary {
        guard !samples.isEmpty else {
            return Summary(calls: 0, failures: 0, elapsedSeconds: elapsedSeconds,
                           throughputPerSecond: 0, p50Ms: 0, maxMs: 0, firstError: nil)
        }
        let failures = samples.filter { !$0.ok }
        let sortedMs = samples.map(\.ms).sorted()
        let p50Index = min(sortedMs.count - 1, max(0, Int(Double(sortedMs.count) * 0.5)))
        let throughput = elapsedSeconds > 0 ? Double(samples.count) / elapsedSeconds : 0
        return Summary(
            calls: samples.count, failures: failures.count, elapsedSeconds: elapsedSeconds,
            throughputPerSecond: throughput, p50Ms: Int(sortedMs[p50Index].rounded()),
            maxMs: Int((sortedMs.last ?? 0).rounded()), firstError: failures.first?.error)
    }
}

/// 並列レーンからの進捗を直列化するためだけの最小カウンタ
private actor ProgressCounter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
