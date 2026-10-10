/// 画像整定(`X-FT-Settle-Mode: image`)の上限を、アプリの UI フレームワークと OS で決める表。
/// `ImageSettlePlan.plan` が `capMs` として引き、BridgeClient が `BridgeAPI.settleCapHeader` でブリッジへ渡す
/// (ブリッジは受け取った上限で打ち切る。ヘッダが無いときはブリッジ側の既定 = その OS の最大)。
/// 上限は「止まらない画面」でだけ払う額(止まれば窓 `imageSettleQuietSeconds` 経過で抜ける)。
///
/// 値はユーザー決定。根拠は E2E の SUT の全画面リストのスワイプで、撃ってから描画が止まるまでの
/// 実測最大(描画プローブ・平常と CPU 100% 負荷を合わせて n=82〜120): iOS SwiftUI 3.673s / RN 2.717s /
/// Flutter 2.911s / CMP 4.355s(減速の最後に約 370ms おき 1px の這う尾がある)/ Android View 1.649s /
/// CMP 1.303s / RN 2.255s / Flutter 1.379s。尽きたら動いたまま返し、注記 "image settle cap" を残す。
/// iOS RN だけは実測最大 2.717s に対し 3.0s(2.8s では静止の窓 0.45s の分が足りず 1/5 で上限に当たった)。
/// iOS の uikit は測っていない(SwiftUI と同じ UIScrollView の減速なので同じ値)。
public enum ImageSettleCap {
    /// iOS で UI フレームワークが分からないときの上限 = iOS の表の最大
    public static let iosFallbackSeconds = 4.4
    /// Android で UI フレームワークが分からないときの上限 = Android の表の最大
    public static let androidFallbackSeconds = 2.3

    public static func seconds(framework: AppUIFramework?, isAndroid: Bool) -> Double {
        if isAndroid {
            switch framework {
            case .androidView: return 1.7
            case .compose: return 1.3
            case .reactNative: return 2.3
            case .flutter: return 1.4
            case .swiftUI, .uikit, nil: return androidFallbackSeconds
            }
        }
        switch framework {
        case .swiftUI, .uikit: return 3.7
        case .reactNative: return 3.0
        case .flutter: return 3.0
        case .compose: return 4.4
        case .androidView, nil: return iosFallbackSeconds
        }
    }
}
