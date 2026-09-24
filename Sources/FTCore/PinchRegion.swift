// 対象を指定しないピンチを、画面のどこへ当てるかの判定(純粋関数)。**DSL・MCP・ライブ操作が共有する**。
//
// **なぜ要るか**(実測 2026-09-22・Apple マップ / iPhone 17 Pro iOS 27.0):
// 指の2点が**別々のものに載る**と、ピンチにならず片方に持っていかれる。マップでは地図の容器
// (`ChromeViewController.Viewport`)の下端が検索カードに接しているため、端に指を置くと
// 下の1本がカードに取られ、地図から見ると指1本 = **パン**になった(POI 間の距離比 1.000 =
// ズーム 0、重心だけが移動)。逆に指が中身に収まっていれば正しくズームする(距離比 1.803)。
//
// そこで**両方の指が同じものに載る位置**を探して、その領域だけを送る。
// 領域の中で指をどう置くか(`FTCore.PinchGesture.ios` / `.android`)は
// この型の外にある —— **端の取り方は `closingTouchPoints` が唯一の定義元**で、
// `PinchGesture.ios` はその2点より内側(0.8 掛け)に指を置く(片方だけ変えない)。

import Foundation

public enum PinchRegion {

    /// 指を広げる半径の候補(画面の短辺に対する割合)。先頭が既定で、置けなければ順に狭める。
    /// 既定 0.22 は座標ピンチの既定半径(`MCPServer.pinchRadiusScreenRatio`)と同じ値。
    /// **下限 0.08 より狭くしない** —— 指が近すぎるとズームとして認識されない
    public static let radiusFractions = [0.22, 0.17, 0.12, 0.08]

    /// 対象未指定のピンチを当てる領域。**両方の指が同じものに載る**位置を探して返す。
    /// nil = どう置いても2点が別々のものに載る(呼び手は画面全体で撃つ = 従来どおり)。
    ///
    /// **呼ぶのは指を領域の端に置く経路(iOS = XCUITest)だけ**。Android は領域の**短辺**から
    /// 指の幅を決めて中心に置くので、狭い領域を渡すと最小スケール幅(27mm)に届かず
    /// ズームにならない(実測 2026-09-22: E2E の対象未指定 pinchOut が `zoom=-` になった)。
    ///
    /// 横向きを先に試すのは、**縦長の画面では上下に別のもの(バー・シート)が載りやすい**ため。
    public static func area(elements: [ElementInfo], screen: FTRect) -> FTRect? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let centreX = screen.x + screen.width / 2
        let centreY = screen.y + screen.height / 2
        let shortSide = min(screen.width, screen.height)
        guard let centreOwner = topmost(at: (centreX, centreY), in: elements) else { return nil }

        for fraction in radiusFractions {
            let radius = shortSide * fraction
            for vertical in [false, true] {
                let ends = endpoints(centreX: centreX, centreY: centreY,
                                     radius: radius, vertical: vertical)
                guard ends.allSatisfy({ point in
                    guard let owner = topmost(at: point, in: elements) else { return false }
                    return sameContent(owner, centreOwner)
                }) else { continue }
                return vertical
                    ? FTRect(x: centreX - radius / 2, y: centreY - radius,
                             width: radius, height: radius * 2)
                    : FTRect(x: centreX - radius, y: centreY - radius / 2,
                             width: radius * 2, height: radius)
            }
        }
        return nil
    }

    /// 領域の中で指が置かれる**もっとも外側**の2点。
    /// **向きの規則は `PinchGesture.ios` と同じ** —— 原則は横並びで、
    /// よほど縦長の枠のときだけ縦(縦に並べると縦スクロールの recognizer が指を取る)。
    /// `PinchGesture.ios` は実際にはここから少し内側に置く(縁ちょうどは隣に拾われる)ので、
    /// **この2点で確かめておけば内側は必ず同じものの上**になる。片方だけ変えない
    public static func closingTouchPoints(in frame: FTRect) -> [(x: Double, y: Double)] {
        let vertical = frame.height > frame.width * 2
        return endpoints(centreX: frame.x + frame.width / 2, centreY: frame.y + frame.height / 2,
                         radius: (vertical ? frame.height : frame.width) / 2,
                         vertical: vertical)
    }

    private static func endpoints(centreX: Double, centreY: Double,
                                  radius: Double, vertical: Bool) -> [(x: Double, y: Double)] {
        vertical
            ? [(centreX, centreY - radius), (centreX, centreY + radius)]
            : [(centreX - radius, centreY), (centreX + radius, centreY)]
    }

    /// その点で**一番手前**にある要素(描画順は `PaintOrder` が唯一の定義元)
    private static func topmost(at point: (x: Double, y: Double),
                                in elements: [ElementInfo]) -> ElementInfo? {
        var best: ElementInfo?
        for element in elements where contains(element.frame, point) {
            if best == nil || PaintOrder.drawnAbove(element, best!) { best = element }
        }
        return best
    }

    /// 「同じものに載っている」か。**入れ子は同じとみなす** —— 地図の上のピンや容器の子で
    /// 弾くと、実際には同じ地図の上なのに置けないと答えてしまう。
    /// 木は親子を持たないので枠の包含で代用する(シートと地図は互いに包まないので分かれる)
    private static func sameContent(_ a: ElementInfo, _ b: ElementInfo) -> Bool {
        a.ref == b.ref || isInside(a.frame, b.frame) || isInside(b.frame, a.frame)
    }

    private static func contains(_ frame: FTRect, _ point: (x: Double, y: Double)) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.x <= point.x && point.x <= frame.x + frame.width
            && frame.y <= point.y && point.y <= frame.y + frame.height
    }

    private static func isInside(_ inner: FTRect, _ outer: FTRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }
}
