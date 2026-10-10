/// waitForSettle の既定値(ユーザー決定)。
///
/// 静止の窓は「慣性の終わりに出る描画の間隔の最大」を覆う長さ(短いと這う動きの途中で「止まった」と誤る)。
/// 実測(E2E の SUT の全画面リストのスワイプ・描画プローブと密な撮影の記録・平常と CPU 100% 負荷):
/// iOS CMP は最後の 1px ずつの這いで最大 650ms(Simulator・SE3)/ SwiftUI 368ms / Android は負荷時 385ms(RN)・
/// 平常 295ms 以下。各約 1.2 倍で丸めた。記録は docs/performance-tuning.md §3.34
public enum WaitForSettleDefaults {
    /// 既定の静止の窓(秒)。iOS で UI フレームワークが分からないときは最大(CMP)に倒す
    public static func quietSeconds(framework: AppUIFramework?, isAndroid: Bool) -> Double {
        if isAndroid { return 0.5 }
        switch framework {
        case .compose, .androidView, nil: return 0.8
        case .swiftUI, .uikit, .reactNative, .flutter: return 0.5
        }
    }
}
