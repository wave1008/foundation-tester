// [PoC occlusion-guard] FM/スクショを使わない Tier-0 の幾何ヒューリスティック。
// スナップショット(ツリー)だけで occlusion の疑いを検出し、疑わしい時だけ FM に回すための前段。
// ピクセル事前フィルタ([RegionInk])が苦手な「部分的な覆い(残テキストのインクが多く高分散に見える)」
// を、覆う要素がツリーに載っているケースで拾うのが主目的。OR で併用する。

import Foundation

public enum OcclusionSuspicion {
    /// ツリーのみで occlusion を疑うか。true=疑い(FM へ)/false=幾何的には無罪。
    /// - looseMatch: ロケータが部分一致(substring)で解決した=別要素を掴んだ疑い。
    /// - overlapFraction: 対象 frame をこの割合以上覆う「手前寄りの別要素」があれば疑う。
    ///   手前寄りは snapshot の記載順(後=手前に描かれやすい)で近似する。a11y 順は z 順の保証では
    ///   ないため過検出寄り(疑い側に倒す=FM を1回余計に呼ぶだけで安全側)。
    public static func geometric(element: ElementInfo, in elements: [ElementInfo],
                                 screen: FTRect, looseMatch: Bool,
                                 overlapFraction: Double = 0.4) -> Bool {
        if looseMatch { return true }
        let t = element.frame
        // 画面外へはみ出す=可視部分が切れる
        if t.x < -0.5 || t.y < -0.5
            || t.x + t.width > screen.width + 0.5
            || t.y + t.height > screen.height + 0.5 { return true }
        return covering(element: element, in: elements, screen: screen,
                        overlapFraction: overlapFraction) != nil
    }

    /// 対象を覆っている「手前寄りの別要素」。無ければ nil。
    /// **失敗メッセージ用**(アプリ内メッセージ・モーダルの特定)。同一プロセスの覆いは
    /// `AndroidForegroundWindows`(別プロセスの window)では捕まらないので、判定はこちらが担う。
    /// 判定規則は geometric と共有する = 「FM へ回すか」と「誰が覆っているか」がずれない。
    /// **手前かどうかは `PaintOrder` に委ねる**(MCP の RefGuard と同じ判定を使う)。
    /// ブリッジが塗り順を申告する木(Android)では本物の z 順、持たない木(iOS)では
    /// 従来どおりツリー順の近似 —— **近似のときだけ過検出寄り**なので、
    /// ステップを落とす根拠には使わないこと。
    ///
    /// 実測(2026-08-07・固定コーパス): ツリー順のままだと Google マップの詳細画面で
    /// **90要素中81件**が「疑い」になり(FM は約1回/秒の直列資源なので実時間に効く)、
    /// 逆に**シートの裏に潜った地図 chrome は1件も拾えなかった**(シートが chrome より先に出るため)。
    public static func covering(element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect, overlapFraction: Double = 0.4) -> ElementInfo? {
        let t = element.frame
        let area = max(1, t.width * t.height)
        // **いちばん手前を返す**(2026-08-07 のレビュー)。配列順で最初に見つけたものを返すと、
        // 重なりが複数あるとき中間層(暗幕など)を名指しして、実際に見えている最前面を素通しする。
        // 塗り順が採れるなら最前面は計算できるので、そちらを答えにする
        var frontmost: ElementInfo?
        for other in elements where other.ref != element.ref {
            guard PaintOrder.drawnAbove(other, element) else { continue }
            guard intersectionArea(t, other.frame) / area >= overlapFraction else { continue }
            // Compose-iOS の frame クランプで画面外行が画面端の同一座標へ潰れて生じる ghost スタックは
            // occluder とみなさない(見えている端要素へ余分な FM を誘発する。docs compose-ios-ax-frame-clamp)。
            if isClampGhost(other.frame, in: elements, screen: screen) { continue }
            if let best = frontmost, !PaintOrder.drawnAbove(other, best) { continue }
            frontmost = other
        }
        return frontmost
    }

    static func intersectionArea(_ a: FTRect, _ b: FTRect) -> Double {
        let x = max(a.x, b.x), y = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        return max(0, right - x) * max(0, bottom - y)
    }

    /// クランプ ghost = 「画面端に接する」かつ「同一 frame の要素が3つ以上(潰れた行スタック)」。
    /// 親子で frame を共有するだけの2重複は本物の occluder を守るため除外しない(閾値3)。
    static func isClampGhost(_ f: FTRect, in elements: [ElementInfo], screen: FTRect,
                             tol: Double = 1.0) -> Bool {
        let atEdge = abs(f.y) <= tol || abs(f.x) <= tol
            || abs(f.y + f.height - screen.height) <= tol
            || abs(f.x + f.width - screen.width) <= tol
        guard atEdge else { return false }
        var duplicates = 0
        for e in elements where frameApproxEqual(e.frame, f, tol: tol) {
            duplicates += 1
            if duplicates >= 3 { return true }
        }
        return false
    }

    static func frameApproxEqual(_ a: FTRect, _ b: FTRect, tol: Double) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
}
