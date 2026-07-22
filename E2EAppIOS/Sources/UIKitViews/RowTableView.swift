import SwiftUI
import UIKit

// スクロール画面は **UIKit の UITableView** を使う(SwiftUI List ではない)。
// 狙いは型語彙のカバレッジ: 生の UITableView は Table / Cell としてツリーに出るため、
// scrollTo と「exist/textIs は非スクロール」の契約をネイティブのリスト実装で検証できる。
struct RowTableView: UIViewRepresentable {
    @Binding var selected: String
    /// 変化させると先頭までスクロールする(#btn_scroll_top 用のワンショット信号)。
    let scrollToTopToken: Int

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView()
        table.accessibilityIdentifier = "tbl_rows"
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.rowHeight = 56  // 56pt 未満は高密度スクロールで frame が崩れ tap が外れる(契約 §全体規約)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        return table
    }

    func updateUIView(_ uiView: UITableView, context: Context) {
        context.coordinator.selected = $selected
        if context.coordinator.lastScrollToken != scrollToTopToken {
            context.coordinator.lastScrollToken = scrollToTopToken
            uiView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var selected: Binding<String>
        var lastScrollToken = 0
        init(selected: Binding<String>) { self.selected = selected }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            Tags.rowCount
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            let n = indexPath.row + 1
            cell.textLabel?.text = Tags.rowLabel(n)
            // セル再利用で id/ラベルがずれないよう毎回書き直す。
            cell.accessibilityIdentifier = Tags.row(n)
            // 既定では textLabel が独立した StaticText として出て Cell 側が無ラベルになる。
            // ラベルを Cell に集約しないと `.Cell=行 01` のラベルセレクタが引けない。
            cell.textLabel?.isAccessibilityElement = false
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = Tags.rowLabel(n)
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: false)
            selected.wrappedValue = Tags.row(indexPath.row + 1)
        }
    }
}
