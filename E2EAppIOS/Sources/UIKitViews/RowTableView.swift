import SwiftUI
import UIKit

// スクロール画面は **UIKit の UITableView** を使う(SwiftUI List ではない)。
// 狙いは型語彙のカバレッジ: 生の UITableView は Table / Cell としてツリーに出るため、
// scrollTo と「exist/textIs は非スクロール」の契約をネイティブのリスト実装で検証できる。
struct RowTableView: UIViewRepresentable {
    @Binding var selected: String
    /// いま表示領域に一部でも見えている最初の行(#txt_scroll_top 用。1 始まり)。
    @Binding var topVisibleRow: Int
    /// 変化させると先頭までスクロールする(#btn_scroll_top 用のワンショット信号)。
    let scrollToTopToken: Int

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView()
        table.accessibilityIdentifier = Tags.listRows
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.rowHeight = 56  // 56pt 未満は高密度スクロールで frame が崩れ tap が外れる(契約 §全体規約)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        return table
    }

    func updateUIView(_ uiView: UITableView, context: Context) {
        context.coordinator.selected = $selected
        context.coordinator.topVisibleRow = $topVisibleRow
        if context.coordinator.lastScrollToken != scrollToTopToken {
            context.coordinator.lastScrollToken = scrollToTopToken
            uiView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected, topVisibleRow: $topVisibleRow) }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var selected: Binding<String>
        var topVisibleRow: Binding<Int>
        var lastScrollToken = 0
        init(selected: Binding<String>, topVisibleRow: Binding<Int>) {
            self.selected = selected
            self.topVisibleRow = topVisibleRow
        }

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

        // 初期表示(まだ1度もスクロールしていない)でも #txt_scroll_top を埋めるため、
        // scrollViewDidScroll だけでなくセルが表示に入るたびにも取り直す。
        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            updateTopVisibleRow(tableView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            updateTopVisibleRow(tableView)
        }

        private func updateTopVisibleRow(_ tableView: UITableView) {
            guard let first = tableView.indexPathsForVisibleRows?.map({ $0.row }).min() else { return }
            let n = first + 1
            if topVisibleRow.wrappedValue != n {
                topVisibleRow.wrappedValue = n
            }
        }
    }
}
