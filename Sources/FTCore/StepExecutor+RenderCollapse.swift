// StepExecutor+RenderCollapse.swift
// 描画崩壊(`RenderCollapse` の doc)の確かめ。**テキストの可視性検証が画素で文字を確かめなかった検証**が緑になったら義務を貯め、
// 区切り(アプリのプロセスが入れ替わる直前・afterEach の前・シナリオの終わり = FTRuntime.renderCollapseCheckpoint)で1回だけ撮る。
// 区切りで足りる根拠: 崩壊したプロセスは起動し直すまで戻らなかった(崩壊したプロセスを触らずに撮り続けた観察)。
// 検証のたびに撮らない理由: 撮影は Simulator で 1 回 100〜115ms(実測)で、E2E の iOS の 1 本あたり平均 6.6 回の検証に掛かる。
// 文字の検証が画素で文字を確かめた時点で義務を下ろす(そのときは描けていた)。Simulator の iOS だけ(ユーザー決定)

import Foundation

extension StepExecutor {

    /// 描画崩壊を確かめるか。**Simulator の iOS だけ**(ユーザー決定。崩壊を観測したのは Simulator だけ)、かつ
    /// **自前描画(Compose・Flutter)か、フレームワークが分からないとき**だけ。SwiftUI・UIKit・RN は省く —— 失敗レポートの
    /// iOS の画面写真 2,453 枚への全数当てで、崩壊の当たりは Compose・Flutter のアプリだけ(RN 0 / 192、SwiftUI は全面が黒い
    /// 写真 3 / 648)。アプリが自分で Metal の面に描くフレームワークだけが描画の経路ごと壊れる。分からないときは確かめる側に倒す
    public static func checksRenderCollapse(platform: String, physical: Bool, framework: AppUIFramework?) -> Bool {
        platform == "ios" && !physical && (framework?.isSelfRendered ?? true)
    }

    /// 検証が緑になったら、画素で文字を確かめたかで義務を貯める・下ろす(execute の assert の枝が呼ぶ)
    func noteAssertionForRenderCollapse(_ assert: String, step: FlowStep, status: StepResult.Status) {
        guard renderCollapseCheckEnabled, Self.isSuccess(status) else { return }
        if pixelsShowedTextThisStep {
            assertionsWithoutPixelProof.removeAll()
            return
        }
        assertionsWithoutPixelProof.append(step.locator == nil ? assert : "\(assert) \(step.locatorSummary)")
    }

    /// 区切りで1回撮って描画崩壊を確かめる。崩壊していれば失敗文、それ以外(義務が無い・崩壊していない・撮れない)は nil。
    /// 当たったら `renderCollapseRetakeSeconds` 待って撮り直し、同じときだけ言う(遷移の途中の一瞬を崩壊と呼ばない)。
    /// 撮れない・読めないは nil(判定できないことを崩壊と呼ばない)。呼ぶと義務は下ろす
    public func renderCollapseVerdict() async -> String? {
        guard renderCollapseCheckEnabled, !assertionsWithoutPixelProof.isEmpty else { return nil }
        let pending = assertionsWithoutPixelProof
        assertionsWithoutPixelProof.removeAll()
        guard await renderCollapseFinding() != nil else { return nil }
        try? await Task.sleep(nanoseconds: UInt64(Self.renderCollapseRetakeSeconds * 1_000_000_000))
        guard let finding = await renderCollapseFinding() else { return nil }
        return Self.renderCollapseMessage(finding, unverified: pending)
    }

    /// 撮影と木を1組読んで判定する
    func renderCollapseFinding() async -> RenderCollapse.Finding? {
        // 陽性対照の注入(`renderCollapseInjectionKey`)。崩壊は意図して起こせないので、観測の答えだけを差し替える
        if renderCollapseInjected { return .noTextDrawn(textElements: 0) }
        guard let tree = try? await driver.snapshot(bypassingCache: true),
              let shot = try? await driver.screenshot() else { return nil }
        return RenderCollapse.judge(pngData: shot, elements: tree.elements, screen: tree.screen,
                                    keyboard: tree.keyboardFrame, inkThreshold: occlusionInkThreshold,
                                    minimumTextElements: RenderCollapse.minimumTextElements)
    }

    /// 失敗文(事実だけ。原因は書かない = ツールには測れない)
    static func renderCollapseMessage(_ finding: RenderCollapse.Finding, unverified: [String]) -> String {
        let seen: String
        switch finding {
        case .blankAppArea(let count):
            seen = "the app's area of the screenshot is a single colour, although the tree reports \(count) text"
                + " element(s) there"
        case .noTextDrawn(let count):
            seen = "none of the \(count) text element(s) the tree reports is drawn in the screenshot (shapes may be drawn,"
                + " text is not)"
        }
        let names = unverified.prefix(3).joined(separator: ", ") + (unverified.count > 3 ? ", …" : "")
        return "the screen is not rendered: \(seen), on two screenshots \(FTSeconds.format(renderCollapseRetakeSeconds))s"
            + " apart. \(unverified.count) check(s) since the last confirmed drawing passed without looking at the"
            + " screen (\(names)), so their results cannot be trusted"
    }

    /// 撮り直すまでの待ち(秒)。**根拠**: 画面の遷移のアニメーションは UIKit 約 0.35 秒・Compose の既定 300ms で、
    /// 起動画面から最初の描画もその桁。その約 3 倍。**尽きたときの発話**: 撮り直しても同じなら崩壊として赤にする
    static let renderCollapseRetakeSeconds: Double = 1.0

    /// 計測の注入口の環境変数(値 "1")。**判定と赤の経路だけ**を毎回通す(デバイスを触る操作は足さない)
    public static let renderCollapseEveryAssertionKey = "FT_RENDER_COLLAPSE_EVERY_ASSERTION"
    /// 陽性対照の注入口の環境変数(値 "1")。判定の答えだけを「崩壊」に差し替える(撮影・木の読みは通常どおり)
    public static let renderCollapseInjectionKey = "FT_FAKE_RENDER_COLLAPSE"
}
