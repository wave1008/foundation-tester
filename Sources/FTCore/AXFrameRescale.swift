// AXFrameRescale.swift
// Flutter の iOS は、画面にオーバーレイ(Tooltip・Dialog 等)を一度出すと、その画面(ルート)の AX 矩形を
// **1/画面倍率に縮めたまま**申告し続ける(次の画面遷移で戻る。in-app・XCUITest とも同じ値 = Flutter 側の申告)。
// 実測 iPhone 17 Pro(倍率 3): FlutterView と根の容器は 402x874 のまま、**ルートのノードだけが
// 134x291.3 = 402x874 ÷ 3** と申告し、その下の全要素が同じ比で縮む(戻るボタン 56pt → 18.7pt・y 62 → 20.7)。
// その「ちょうど画面倍率で割った FlutterView の枠」を申告するノードを見つけ、その下を実の枠へ写す純粋判定。
// **in-app ブリッジと共有**(InAppBridge/build.sh の SWIFT_SOURCES と BridgeSourceSet の inApp に載っている =
// 触ったら bridgeProtocolVersion を上げる)。Foundation と FTRect(BridgeDTO)以外に依存しない

import Foundation

public struct AXFrameRescale: Equatable {
    /// 縮んだノードが申告した矩形
    public let reported: FTRect
    /// FlutterView の実の枠(window 座標)
    public let actual: FTRect

    /// 申告と「FlutterView ÷ 倍率」の一致の許容(pt。浮動小数の丸め)
    static let tolerance = 1.0

    /// `reported` が**ちょうど `view` を `screenScale` で割った矩形**(原点も同じく割る)なら、その下を
    /// `view` へ写す補正を返す。**それ以外は nil** = 申告をそのまま使う(このずれの形でないものを推測で写さない)。
    /// 倍率 1 の画面では割っても変わらないので判定しない
    public static func shrunkSubtree(reported: FTRect, view: FTRect, screenScale: Double) -> AXFrameRescale? {
        guard screenScale > 1, view.width >= 1, view.height >= 1 else { return nil }
        let expected = FTRect(x: view.x / screenScale, y: view.y / screenScale,
                              width: view.width / screenScale, height: view.height / screenScale)
        guard abs(reported.x - expected.x) <= tolerance, abs(reported.y - expected.y) <= tolerance,
              abs(reported.width - expected.width) <= tolerance,
              abs(reported.height - expected.height) <= tolerance else { return nil }
        return AXFrameRescale(reported: reported, actual: view)
    }

    public func apply(_ frame: FTRect) -> FTRect {
        let sx = actual.width / reported.width
        let sy = actual.height / reported.height
        return FTRect(x: actual.x + (frame.x - reported.x) * sx,
                      y: actual.y + (frame.y - reported.y) * sy,
                      width: frame.width * sx,
                      height: frame.height * sy)
    }
}
