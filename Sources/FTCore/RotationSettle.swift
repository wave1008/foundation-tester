// RotationSettle.swift
// ft_rotate(MCP)向けの純粋判定。定数(deadlineSeconds/pollIntervalSeconds)は BridgeDTO.swift の
// RotationSettle 列挙(ランナー側の待ち予算)に既にある — ここは同じ型へ「読みが収まっているか」の
// 判定だけを別ファイルで足す(BridgeDTO.swift はブリッジのソース集合 = 触ると dylib 再ビルドの
// 指紋ゲートが鳴るので編集しない)。

import Foundation

extension RotationSettle {
    /// 縁のはみ出し許容(pt)。厳密一致だと座標の丸めだけで false になるので1pt遊ばせる
    public static let edgeOverflowTolerance: Double = 1

    /// すべての要素の frame が screen の内側(縁が `tolerance` を超えてはみ出していない)か。
    ///
    /// **判定は縁(maxX/maxY)であって中心ではない**: 実機 iPhone 13 の witness ——
    /// XCUITest ランナーは `app.frame` が反転した時点で返すため(BridgeRouter.swift)、
    /// 回転直後の1枚目は screen が新しい向き(390x844)なのに要素は旧向きのレイアウトのまま
    /// (`#screen_wishlist (17,35 519x537)`)。この要素の中心 x=276.5 は幅390の内側に収まって
    /// しまい中心判定では見逃すが、右端 536 は 390 を大きく超える
    public static func framesFitScreen(_ snapshot: SnapshotResponse,
                                       tolerance: Double = edgeOverflowTolerance) -> Bool {
        let maxX = snapshot.screen.x + snapshot.screen.width + tolerance
        let maxY = snapshot.screen.y + snapshot.screen.height + tolerance
        return snapshot.elements.allSatisfy {
            $0.frame.x + $0.frame.width <= maxX && $0.frame.y + $0.frame.height <= maxY
        }
    }
}
