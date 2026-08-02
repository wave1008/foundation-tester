import SwiftUI

struct ScrollScreen: View {
    @State private var selected = "-"
    @State private var tagSelected = "-"
    @State private var scrollToken = 0

    var body: some View {
        // ScreenColumn は使わず自前で組む: UITableView を残り高さいっぱいに伸ばすため。
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtRowSelected, text: "selected=\(selected)")
            TaggedButton(tag: Tags.btnScrollTop, label: "先頭へ") { scrollToken += 1 }
            RowTableView(selected: $selected, scrollToTopToken: scrollToken)
            // 横スクロールの検証材料(scrollFrame)。**リストの下に置く** —— 画面中央に置くと
            // 領域を指定しない従来スクロール(画面中央基準)がカルーセルに吸われる。
            // **1画面に 3〜4 個しか入らない幅**にする ——
            // 全部見えていると「横スクロールした」ことを不在で検証できない
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(1...Tags.tagCount, id: \.self) { n in
                        TaggedButton(tag: Tags.tag(n), label: Tags.tagLabel(n)) {
                            tagSelected = Tags.tag(n)
                        }
                        .frame(width: 120, height: 56)
                    }
                }
            }
            .frame(height: 60)
            .accessibilityIdentifier(Tags.carouselTags)
            TaggedText(tag: Tags.txtTagSelected, text: "tag=\(tagSelected)")
        }
        .padding(16)
    }
}

struct AsyncScreen: View {
    @State private var state = "idle"
    @State private var showDelayed = false
    @State private var countdown: Int? = nil
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtDelayState, text: "state=\(state)")
            TaggedButton(tag: Tags.btnDelay1, label: "1秒後に表示") { startDelay(1, withCountdown: false) }
            TaggedButton(tag: Tags.btnDelay3, label: "3秒後に表示") { startDelay(3, withCountdown: true) }
            TaggedButton(tag: Tags.btnDelay8, label: "8秒後に表示") { startDelay(8, withCountdown: false) }
            // showDelayed=false の間はツリーに置かない(非表示ではなく未配置であることが検証点)。
            if showDelayed {
                TaggedText(tag: Tags.txtDelayed, text: "遅延表示 完了")
            }
            if let n = countdown {
                TaggedText(tag: Tags.txtCountdown, text: "count=\(n)")
            }
            TaggedButton(tag: Tags.btnAsyncReset, label: "非同期リセット") {
                task?.cancel()
                task = nil
                state = "idle"
                showDelayed = false
                countdown = nil
            }
        }
    }

    private func startDelay(_ seconds: Int, withCountdown: Bool) {
        // 前回タイマを cancel しないと、古い遅延が後から done を書き込んで検証を壊す。
        task?.cancel()
        state = "waiting"
        showDelayed = false
        countdown = nil
        task = Task { @MainActor in
            do {
                if withCountdown {
                    for n in stride(from: seconds, through: 1, by: -1) {
                        countdown = n
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    countdown = 0
                } else {
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
            } catch {
                return  // cancel された場合は state を書き換えない
            }
            state = "done"
            showDelayed = true
        }
    }
}
