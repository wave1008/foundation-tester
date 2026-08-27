/// **木に出ないオーバーレイ・ウィンドウ**による遮蔽の判定。`KeyboardOcclusion` と同型で、
/// 材料はブリッジ申告の矩形だけ —— 木からは原理的に判定できないから申告が要る。
///
/// なぜ要るか(2026-08-28・実機 Pixel 4a の Chrome で実害確認): Android の木の根は
/// `getRootInActiveWindow()` = **アクティブウィンドウ1枚だけ**なので、その手前に居る
/// 非フォーカスのポップアップ(ツールチップ・テキスト選択のフローティングツールバー・
/// ボトムシート)は `elements` に1要素も載らない。段落の中心をツールバーが覆っている状態で
/// ref タップが無警告の "done" を返し、**実際には「Select all」に当たった**。
/// フォーカスを取るポップアップ(メニュー)は自分がアクティブになるので木が正しく
/// 差し替わる = 壊れるのは**フォーカスを取らない窓**だけ。
///
/// 同じ失敗は 2026-08-08 に IME で1度観測して `keyboardFrame` だけを塞いであった。
/// **同型が IME 以外の全ウィンドウに残っていた**のがこの型の存在理由。
///
/// **警告のみ**(新しい検知は拒否でなく警告から)。申告が無い(旧ブリッジ・iOS)ときは
/// `.none` に落ちて従来動作のまま。
public struct OverlayWindowOcclusion: Sendable {
    /// 覆っている矩形(画面座標)。手前に居る順序は問わない —— 中心を含む最初の1枚を使う
    public let frames: [FTRect]

    public static let none = OverlayWindowOcclusion(frames: [])

    public init(frames: [FTRect]) {
        self.frames = frames
    }

    /// 申告が無い/空/退化した矩形しか無ければ `.none`。
    /// **面積で足切りしない** —— 全画面のオーバーレイは「木が丸ごと後ろに居る」最も危険な形で、
    /// そこで黙ると一番言うべきときに言わないことになる
    public static func resolve(reported: [FTRect]?) -> OverlayWindowOcclusion {
        guard let reported else { return .none }
        let usable = reported.filter { $0.width > 0 && $0.height > 0 }
        return usable.isEmpty ? .none : OverlayWindowOcclusion(frames: usable)
    }

    /// 要素の**中心**を含む矩形(無ければ nil)。判定を中心点だけにするのは
    /// `keyboardCoveredAdvisory` と揃えるため —— 撃つ点がそこだから
    public func covering(_ element: ElementInfo) -> FTRect? {
        let cx = element.frame.centerX
        let cy = element.frame.centerY
        return frames.first {
            cx >= $0.x && cx <= $0.x + $0.width && cy >= $0.y && cy <= $0.y + $0.height
        }
    }

    /// 中核の1文。**呼び手(DSL / MCP)は前後の名指しと逃げ道を自分で足す**
    /// (`KeyboardOcclusion.advisory` と同じ分担)
    public func advisory(for element: ElementInfo) -> String? {
        guard covering(element) != nil else { return nil }
        let cx = Int(element.frame.centerX)
        let cy = Int(element.frame.centerY)
        return "its centre (\(cx), \(cy)) is under an overlay window that is not in the tree"
            + " (a popup, tooltip, floating toolbar or sheet drawn above the app) — the tap will"
            + " land on that overlay, not this element. Dismiss it first (go back, or tap a"
            + " neutral spot), then read the screen again"
    }

    public func covers(_ element: ElementInfo) -> Bool { covering(element) != nil }
}
