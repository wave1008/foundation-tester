import Foundation

/// 操作の種類(画像整定の計画を分ける軸)。ブリッジのパスから `ImageSettlePlan.kind(forBridgePath:)` で引く
public enum ImageSettleActionKind: Equatable, Sendable { case tap, text, scroll }

/// 画像整定(`X-FT-Settle-Mode: image`)の操作ごとの計画。ホストが決め、BridgeClient がヘッダで渡す
/// (`BridgeAPI.settleQuietHeader` 等。ブリッジはヘッダが無いとき・範囲外のとき自分の既定)。
/// `StepExecutor.execute` がステップの間 `context` に UI フレームワークと OS を載せる。上限は `ImageSettleCap` の表。
///
/// 値の根拠(E2E の SUT・描画プローブ・平常と CPU 100% 負荷の合算。ユーザー承認):
/// - タップ/入力の窓 250ms(iOS) = タップ後の描画間隔の実測最大 196ms × 1.3。
/// - iOS UIKit 系(SwiftUI/UIKit/RN)のスクロール: XCTest の完了通知は慣性の終わりと一致する(−0.16〜+0.02 秒)ので
///   減速の尾(描画間隔の最大 368ms)を窓で覆わなくてよい → 通知を待ってから窓 250ms(`waitEvent`)。
/// - iOS 自前描画のスクロール: Flutter は尾の描画間隔の最大 64ms → 250ms。CMP は窓 450ms。CMP の慣性の最後
///   (撃ってから 3.8〜4.4 秒)には 1px ずつの這いがあり、枠の内側 80% の密な撮影記録で間隔が最大 650ms(15 本中 7 本が
///   450ms 超)= 窓は這いを「止まった」とみなして返す(ユーザー決定。広げると 600ms で 15 本中 5 本・700ms で 7 本が
///   上限に達し、毎回「動き続けた」の注記が出る。取りこぼすのは残り数 px)。
///   慣性の間は毎回の絵が前と違うので、撮影の間を 150ms あける(`backoffMs`。無駄な撮影を減らし、窓 450ms より十分短い)。
/// - 自前描画の a11y 木は絵より遅れる(CMP の type(replace:) の失敗・慣性中は木が凍る)ので、
///   タップ/入力はランナーに木の整定も立てさせ(`armTree`)、スクロールはホストが操作後の木の整定を残す(`hostTreeSettle`)。
///   UIKit 系はタップ後の最初の snapshot で木が確定している(240/240)ので木の確認を要さない。
/// - Android の窓は 320ms(ユーザー決定。負荷時のナビゲーションの描画間隔 295ms)。Android ブリッジは a11y の静止待ちを
///   並行して回し木の追いつきを覆うので、ホストの木の整定は要らない。
public struct ImageSettlePlan: Equatable, Sendable {
    /// 静止の窓[ms]。短いと尾の途中で返り、長いと全操作がその分余計に待つ
    public var quietMs: Int
    /// 上限[ms](`ImageSettleCap.seconds` の表)
    public var capMs: Int
    /// iOS のみ: swipe/drag の画像整定の前に XCTest の完了通知を待つ
    public var waitEvent: Bool
    /// iOS のみ: ランナーの次の snapshot の木の整定も立てる
    public var armTree: Bool
    /// iOS のみ: 前の絵と違った撮影の後、次の撮影まで待つ[ms]
    public var backoffMs: Int
    /// スクロール系の操作の後にホストが木の整定(settledSignature / settleAfterScroll)を残すか
    public var hostTreeSettle: Bool

    public struct Context: Equatable, Sendable {
        public var framework: AppUIFramework?
        public var isAndroid: Bool
        public init(framework: AppUIFramework?, isAndroid: Bool) {
            self.framework = framework
            self.isAndroid = isAndroid
        }
    }

    /// ステップ中の文脈。nil = 計画ヘッダを載せない(ブリッジの既定)
    @TaskLocal public static var context: Context?

    public static func plan(framework: AppUIFramework?, isAndroid: Bool,
                            kind: ImageSettleActionKind) -> ImageSettlePlan {
        let capMs = Int((ImageSettleCap.seconds(framework: framework, isAndroid: isAndroid) * 1000).rounded())
        if isAndroid {
            return ImageSettlePlan(quietMs: 320, capMs: capMs, waitEvent: false, armTree: false,
                                   backoffMs: 0, hostTreeSettle: kind != .scroll)
        }
        switch framework {
        case .swiftUI, .uikit, .reactNative:
            return ImageSettlePlan(quietMs: 250, capMs: capMs, waitEvent: kind == .scroll, armTree: false,
                                   backoffMs: 0, hostTreeSettle: false)
        case .flutter:
            return selfRendered(quietScroll: 250, capMs: capMs, kind: kind)
        case .compose, .androidView, nil:
            return selfRendered(quietScroll: 450, capMs: capMs, kind: kind)
        }
    }

    private static func selfRendered(quietScroll: Int, capMs: Int, kind: ImageSettleActionKind) -> ImageSettlePlan {
        if kind == .scroll {
            return ImageSettlePlan(quietMs: quietScroll, capMs: capMs, waitEvent: false, armTree: false,
                                   backoffMs: 150, hostTreeSettle: true)
        }
        return ImageSettlePlan(quietMs: 250, capMs: capMs, waitEvent: false, armTree: true,
                               backoffMs: 0, hostTreeSettle: true)
    }

    /// `FT_SETTLE_MODE` が `tree` 以外(未設定・空・不明な値を含む)なら画像整定。BridgeClient と StepExecutor が共有する
    public static func imageModeEnabled(environment: [String: String]) -> Bool {
        environment[RunEnvironmentKeys.settleMode] != BridgeAPI.settleModeTree
    }

    /// ブリッジのパス → 操作の種類。表に無いパスは tap(ブリッジが画像整定の対象にするパスだけが意味を持つ)
    public static func kind(forBridgePath path: String) -> ImageSettleActionKind {
        switch path {
        case "/swipe", "/drag", "/scrollAction": return .scroll
        case "/type", "/clear", "/pressEnter": return .text
        default: return .tap
        }
    }
}
