// 画像照合の特徴量(GenerateImageFeaturePrintRequest・既定の装置 = ANE)の暖機。OCR モデルのコンパイル(RegionText)とは
// 別のモデル・別の装置なので、あちらがコンパイル済みでもこちらは冷えたまま。
// Vision の異常(縮退・測り直しの不一致)は**プロセスで最初に特徴量を計算したときだけ**起き数秒で戻る
// (`FindImage.anomalyRetryDelays` の doc の実測)ので、シナリオ開始時に裏で計算し、健全な値が返るまで
// 繰り返して、その時間をシナリオの操作(起動・タップ)と重ねる。
// **止めない・数えない**: シナリオは暖機を待たない(照合が先に来たら `anomalyRetryDelays` が拾う)/
// `VisionUsageLedger`・`featurePrintCount` に書かない(照合の実仕事ではない)/ 控えにも書かない。

import CoreGraphics
import Foundation
import Vision

extension FindImage {
    /// 暖機が健全な値を待つ上限。**根拠**(実測・Android E2E 8 並列 + 配信 24fps・266 プロセス): 1 回目で健全が
    /// 78%・健全になるまでの最長は 28.5 秒(52 回目)。その約 2 倍。1 回の確かめは特徴量 2〜3 枚(ANE で約 20ms)なので
    /// 長めに回しても費用は小さい。**尽きても何も変えない**(照合側の `anomalyRetryDelays` が最後の砦)。
    /// 効果(同じ条件): 待って測り直した画像のシナリオは 30/40 → 2/40。残る 2 件はどちらも暖機が終わる前に照合した回
    public static let prewarmBudget: Duration = .seconds(60)
    /// 確かめの間隔(= `anomalyRetryDelays` の最初の待ちと同じ。すぐの撃ち直しでは戻らない実測)
    public static let prewarmInterval: Duration = .milliseconds(500)

    /// 画像の見本(DefaultClassifier)を持つプロジェクトのプロセスでだけ暖機を始める(プロセスに1回)。
    /// 見本が無ければ撃たない(画像照合を使わないプロセスに ANE の負荷を足さない)
    public static func prewarmIfNeeded(projectRoot: URL?, isAndroid: Bool) {
        guard let projectRoot else { return }
        let directory = VisionClassifier.directory(projectRoot: projectRoot, name: DefaultClassifier.name)
        // label "" = 全ラベルの見本(自 OS の印を先に)。最初の1枚で機械の状態を見る(異常は見本を選ばない)
        guard let template = templateFiles(label: "", classifierDirectory: directory, isAndroid: isAndroid).first
        else { return }
        prewarmLock.withLock {
            prewarmRequests += 1
            guard !prewarmStarted else { return }
            prewarmStarted = true
            Task.detached(priority: .utility) {
                guard let image = loadImage(template) else { return }
                _ = await warmUntilHealthy(budget: prewarmBudget, interval: prewarmInterval,
                                           check: { await isHealthy(template: template, image: image) },
                                           sleep: { try? await Task.sleep(for: $0) })
            }
        }
    }

    /// 配線の確認用(テスト)。「暖機を頼んだ回数」で、実際に回した回数ではない
    public static var prewarmRequestCount: Int { prewarmLock.withLock { prewarmRequests } }

    private static let prewarmLock = NSLock()
    nonisolated(unsafe) private static var prewarmRequests = 0
    nonisolated(unsafe) private static var prewarmStarted = false

    /// `check` が true を返すまで `interval` おきに繰り返す。**少なくとも1回は確かめる**。純粋な制御だけ
    static func warmUntilHealthy(budget: Duration, interval: Duration,
                                 check: () async -> Bool,
                                 sleep: (Duration) async -> Void) async -> (healthy: Bool, attempts: Int) {
        var attempts = 0
        var waited: Duration = .zero
        while true {
            attempts += 1
            if await check() { return (true, attempts) }
            guard waited + interval <= budget else { return (false, attempts) }
            await sleep(interval)
            waited += interval
        }
    }

    /// 門(`match`)と同じ判定: 白紙と距離 0 でない・見本の特徴量が永続控え(無ければ直前の計算)と一致する
    private static func isHealthy(template: URL, image: CGImage) async -> Bool {
        do {
            let request = GenerateImageFeaturePrintRequest()
            let blank = try await request.perform(on: blankSentinel)
            let print = try await request.perform(on: image)
            guard !isDegenerate(templateDistanceToBlank: try print.distance(to: blank)) else { return false }
            let reference: FeaturePrintObservation
            if let stored = TemplatePrintStore.lookup(template) {
                reference = stored
            } else {
                reference = try await request.perform(on: image)
            }
            return isConsistent(selfDistance: Double(try reference.distance(to: print)))
        } catch {
            return false
        }
    }
}
