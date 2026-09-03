import SwiftUI

/// **縁の帯に潜った操作対象**の witness(iOS SUT だけが持つ)。
///
/// スクロール内容を**アプリ本体のタブバーの下へ潜らせる**(下方向の負の余白)。
/// 実アプリで頻出する形で、受け手の SUT では 4.7 インチ実機でログアウトがタブバーに潜り、
/// タップがタブ「カート」に当たって7本が巻き添えで落ちた(D-02)。
///
/// **自前のフッタでは witness にならない**(2026-08-27 に実測): ZStack で上に重ねても
/// iOS の a11y の木では容器より**先**に出るため、遮蔽判定(描画順)が成立しない。
/// タブバーはシェルの VStack の最後に置かれるので木でも後になり、判定が成立する。
///
/// 対象の下には送る余地(160pt)を残してある —— 余地が無ければ送っても外れない。
struct CoverScreen: View {
    @State private var result = "none"
    /// **occlusion-guard の FM 経路の witness**(下の `paintedTarget`)。
    /// 詳細は Tags.btnPaintTarget のコメント
    @State private var painted = false

    private let rowCount = 14
    /// タブバーの高さぶん内容を潜らせる。**実測に依らない値**にしない ——
    /// 48(ボタンの高さ)+ 余白 で、対象の中心が確実にタブバーの内側へ入る量
    private let tuckUnderTabBar: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtCoverResult, text: "cover=\(result)")
            paintedTarget
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(1...rowCount, id: \.self) { n in
                            Text("行 \(n)").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        TaggedButton(tag: Tags.btnUnderFooter, label: "下端のボタン",
                                     fillWidth: true) { result = "target" }
                            .id(Tags.btnUnderFooter)
                        Color.clear.frame(height: 160)
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear {
                    // 対象の下端を容器の下端に合わせる = タブバーの下に隠れた状態から始める
                    proxy.scrollTo(Tags.btnUnderFooter, anchor: .bottom)
                }
            }
            .padding(.bottom, -tuckUnderTabBar)
            // **a11y の並び順を内容 → タブバーにする**。iOS には z が無く、遮蔽判定は
            // 木の順序を描画順の代理に使う(FTCore.PaintOrder)。SwiftUI は既定でシェルの
            // タブバーを内容より先に並べるため、この指定が無いと「潜っている」ことを
            // ツールが判定できない(2026-08-27 の実測)
            .accessibilitySortPriority(1)
        }
        .padding(.top, 16)
    }

    /// ラベルを持つボタンを、**文字を1つも持たない不透明な面**で覆う。
    ///
    /// occlusion-guard は「幾何で無罪 かつ 領域にインクがある」なら FM を省く(Tier-1)。
    /// 文字の載った覆い(タブバー・モーダルのカード)ではインクが残るので**FM まで届かない** ——
    /// 2026-09-03 に既存の覆い witness 2形で確かめたところ、どちらも FM 呼び出し 0 で緑になった。
    /// ここは面を無地にしてインクを 0 にし、**FM に訊く経路そのもの**を対照にする。
    ///
    /// **タップは通す**(`allowsHitTesting(false)`)—— この witness が見るのは判定側だけで、
    /// 操作側の「覆いを外してから撃つ」は `#btn_under_footer` が受け持つ。
    private var paintedTarget: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedButton(tag: Tags.btnTogglePaint,
                         label: painted ? "覆いを外す" : "覆いを塗る") { painted.toggle() }
            ZStack {
                TaggedButton(tag: Tags.btnPaintTarget, label: "塗りの下のボタン",
                             fillWidth: true) { result = "paint" }
                if painted {
                    Rectangle()
                        .fill(Color(.systemIndigo))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 62)
        }
        .padding(.horizontal, 16)
    }
}
