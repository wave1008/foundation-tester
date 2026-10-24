// Android のジェスチャナビで、要素を押す点を画面下端のジェスチャ帯の外へ寄せる判定。
// DSL(StepExecutor の tap・長押し・doubleTap)・MCP(ft_tap / ft_long_press / ft_double_tap)・
// ライブ操作(tap / press / doubleTap)が共有する(文言は呼び手ごと)。幾何は ScrollGeometry.tapYClearingBottomGestureBand

import Foundation

public enum BottomGestureBandTap {
    /// 帯の高さの上限の見積り(dp)。AOSP の 3 ボタンのバーの高さ = ジェスチャナビの帯(それ以下)の上限。
    /// 中心がこれより上の要素では帯を問い合わせない(1 回 30〜60ms・約 370KB の dumpsys。読めない端末では控えが
    /// 残らずタップのたびに払う)。`AndroidDriver` の帯のフォールバックも同じ値
    public static let maxBandHeightDp: Double = 48

    /// 押す y。寄せない(iOS・中心が帯の外・帯の幅 0)・寄せられない(要素が帯より上に出ていない)なら nil。
    /// `driver.pointScale` は px/dp(Android の木は px)
    public static func tapY(for frame: FTRect, screen: FTRect, isAndroid: Bool, driver: AppDriver) async -> Double? {
        guard isAndroid,
              frame.centerY >= screen.y + screen.height - maxBandHeightDp * driver.pointScale,
              let band = await driver.backGestureEdgeWidths(), band.bottom > 0 else { return nil }
        return ScrollGeometry.tapYClearingBottomGestureBand(frame: frame, viewport: screen, bottom: band.bottom)
    }
}
