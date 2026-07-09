// HealReviewSheet.swift
// 自己修復(--heal)ONで実行した後の確定フロー。実行中に見つかった修復候補を一覧表示し、
// チェックしたものだけを「はい」でシナリオソースへ確定反映する。
// 「変更後」のセレクタと「説明(変更後)」= 行末コメントは適用前に手で編集できる
// (編集値はシート内の状態で、pendingHealFixes 自体は書き換えない。HealFix.id は
// newSelector を含まないため編集してもヒールキャッシュの削除キーは変わらない)。
// 説明の提案は FM を使わず、新コマンドの自然言語文(StepDescription)を優先し、
// 生成できないときは既存コメント内の旧セレクタ表記→新セレクタのラベル部分の機械置換に
// フォールバックする。コメントの無い行にも生成文があれば「説明の追加」を提案する。
// 「いいえ」は何もしない(ヒールキャッシュはそのまま残り、次回実行でまた同じ提案が出る)。

import FTCore
import FTDSL
import SwiftUI

struct HealReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    /// fix.id → 編集中の「変更後」セレクタ(未編集は fix.newSelector のまま)
    @State private var editedSelectors: [String: String] = [:]
    /// fix.id → 編集中の説明(提案できた fix のみキーが存在 = 説明 UI の表示条件。
    /// 初期値 = 生成文、生成できなければ既存コメントの機械置換)
    @State private var editedComments: [String: String] = [:]
    /// fix.id → シート表示時に読んだソース行の情報(キー無し = 未読込)
    @State private var sources: [String: RowSource] = [:]
    @State private var errorMessage: String?
    @State private var applying = false

    /// ソースの該当行と行末コメント(シート表示時に 1 回読む)
    struct RowSource {
        /// 該当行(nil = 読めない・旧セレクタ不在 = 適用不可)
        let originalLine: String?
        /// 行末コメント = 説明(無い行は nil = 説明の見直しはしない)
        let originalComment: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自己修復の確認")
                .font(.title2.weight(.semibold))
            Text("自己修復されたセレクタがあります。修復内容をシナリオのソースに反映しますか?"
                 + "(「変更後」と「説明(変更後)」は反映前に編集できます)")
                .font(.body)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.pendingHealFixes) { fix in
                        HealFixRow(fix: fix,
                                   checked: checkedBinding(for: fix),
                                   editedSelector: selectorBinding(for: fix),
                                   editedComment: editedComments[fix.id] != nil
                                       ? commentBinding(for: fix) : nil,
                                   source: sources[fix.id])
                            .padding(.vertical, 10)
                        if fix.id != model.pendingHealFixes.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            if let errorMessage {
                Text("❌ \(errorMessage)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("いいえ") { dismiss() }
                Button {
                    Task {
                        applying = true
                        errorMessage = await model.applyHealFixes(checkedFixes)
                        applying = false
                        if errorMessage == nil { dismiss() }
                    }
                } label: {
                    if applying {
                        ProgressView().controlSize(.small).frame(width: 36)
                    } else {
                        Text("はい")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checkedFixes.isEmpty || applying)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 800, minHeight: 420)
        .onAppear {
            // 既定 ON(全件チェック済みの状態で開く)。適用不可の行は読込時に外す
            checked = Set(model.pendingHealFixes.map(\.id))
            loadSources()
        }
    }

    /// 適用対象: チェックされた fix に編集後のセレクタと説明を反映したもの。
    /// 説明は「編集後が元コメント(無ければ空)と異なる場合のみ」newComment に詰める
    /// (空 = コメント削除。コメント無し行+空編集 = 変更なし)。
    /// 不正な編集値は行側でチェックが外れるが、二重の安全のためここでも除く
    private var checkedFixes: [AppModel.HealFix] {
        model.pendingHealFixes
            .filter { checked.contains($0.id) }
            .compactMap { fix in
                let selector = editedSelectors[fix.id] ?? fix.newSelector
                guard Self.isValidSelector(selector) else { return nil }
                var newComment: String?
                if let edited = editedComments[fix.id] {
                    guard Self.isValidComment(edited) else { return nil }
                    let trimmed = edited.trimmingCharacters(in: .whitespaces)
                    if trimmed != (sources[fix.id]?.originalComment ?? "") {
                        newComment = trimmed
                    }
                }
                return AppModel.HealFix(
                    scenarioID: fix.scenarioID, file: fix.file, line: fix.line,
                    oldSelector: fix.oldSelector, newSelector: selector,
                    message: fix.message, newComment: newComment)
            }
    }

    /// セレクタ編集値の検証: 空・「"」・改行はソースのクォート付き文字列を壊すため不可
    static func isValidSelector(_ selector: String) -> Bool {
        !selector.isEmpty && !selector.contains("\"")
            && !selector.contains("\n") && !selector.contains("\r")
    }

    /// 説明編集値の検証: 改行のみ不可(空はコメント削除の意思として許可)
    static func isValidComment(_ comment: String) -> Bool {
        !comment.contains("\n") && !comment.contains("\r")
    }

    // MARK: - ソース行の読込と説明の提案

    /// 各 fix のソース行と行末コメントを読み、説明の初期提案を組み立てる。
    /// 提案 = 新コマンドの自然言語文(生成できればコメント無し行にも「説明の追加」を提案)。
    /// 生成できないときは既存コメントの機械置換、コメントも無ければ説明 UI を出さない。
    /// 提案はここで 1 回だけ生成する(セレクタ編集にライブ追従させるとユーザー編集を壊すため)
    private func loadSources() {
        let root = ScenarioHost.packageRoot()
        for fix in model.pendingHealFixes {
            let line = Self.sourceLine(for: fix, packageRoot: root)
            let comment = line.flatMap { ScenarioSourceComments.trailingComment(inLine: $0) }
            sources[fix.id] = RowSource(originalLine: line, originalComment: comment)
            guard line != nil else {
                checked.remove(fix.id)
                continue
            }
            let generated = fix.command.flatMap {
                StepDescription.describe(command: $0, selectorOverride: fix.newSelector)
            }
            if let generated {
                editedComments[fix.id] = generated
            } else if let comment {
                editedComments[fix.id] = Self.proposedComment(original: comment, fix: fix)
            }
        }
    }

    /// fix の該当ソース行を読む。読めない・行範囲外・旧セレクタ不在なら nil(適用不可)
    private static func sourceLine(for fix: AppModel.HealFix, packageRoot: URL?) -> String? {
        let url = fix.file.hasPrefix("/") ? URL(fileURLWithPath: fix.file)
            : packageRoot?.appendingPathComponent(fix.file)
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let lines = source.components(separatedBy: "\n")
        guard fix.line >= 1, fix.line <= lines.count,
              lines[fix.line - 1].contains("\"\(fix.oldSelector)\"") else {
            return nil
        }
        return lines[fix.line - 1]
    }

    /// 説明(行末コメント)の機械置換提案: コメント内で旧セレクタ全文 → 各 || コンポーネント
    /// の順に探し、最初に見つかった表記の全出現を新セレクタのラベル部分へ置き換える。
    /// どれも見つからなければ元のまま(変更なし提案)
    static func proposedComment(original: String, fix: AppModel.HealFix) -> String {
        let candidates = [fix.oldSelector]
            + fix.oldSelector.components(separatedBy: "||").filter { !$0.isEmpty }
        guard let hit = candidates.first(where: { original.contains($0) }) else {
            return original
        }
        return original.replacingOccurrences(of: hit, with: label(of: fix.newSelector))
    }

    /// セレクタの「ラベル部分」= || 区切りで最初の「# でも . でも始まらない」コンポーネント
    /// (無ければ最初のコンポーネント)
    static func label(of selector: String) -> String {
        let parts = selector.components(separatedBy: "||").filter { !$0.isEmpty }
        return parts.first { !$0.hasPrefix("#") && !$0.hasPrefix(".") } ?? parts.first ?? selector
    }

    // MARK: - バインディング

    private func checkedBinding(for fix: AppModel.HealFix) -> Binding<Bool> {
        Binding(
            get: { checked.contains(fix.id) },
            set: { isOn in
                if isOn { checked.insert(fix.id) } else { checked.remove(fix.id) }
            })
    }

    private func selectorBinding(for fix: AppModel.HealFix) -> Binding<String> {
        Binding(
            get: { editedSelectors[fix.id] ?? fix.newSelector },
            set: { editedSelectors[fix.id] = $0 })
    }

    private func commentBinding(for fix: AppModel.HealFix) -> Binding<String> {
        Binding(
            get: { editedComments[fix.id] ?? "" },
            set: { editedComments[fix.id] = $0 })
    }
}

/// 1 件の修復候補: シナリオID・file:line・変更前後のセレクタ(変更後は編集可)・
/// 説明(行末コメント)の変更前後(変更後は編集可)と、
/// ソース行の diff プレビュー(セレクタ・説明の両編集にライブ追従)
private struct HealFixRow: View {
    let fix: AppModel.HealFix
    let checked: Binding<Bool>
    let editedSelector: Binding<String>
    /// 説明の提案がある fix のみ(nil = 説明 UI を出さない)
    let editedComment: Binding<String>?
    let source: HealReviewSheet.RowSource?

    private static let labelWidth: CGFloat = 110

    /// 読込済みで該当行が取れなかった(ソースが変更されている)
    private var unavailable: Bool {
        source != nil && source?.originalLine == nil
    }

    private var selectorValid: Bool {
        HealReviewSheet.isValidSelector(editedSelector.wrappedValue)
    }

    private var commentValid: Bool {
        guard let editedComment else { return true }
        return HealReviewSheet.isValidComment(editedComment.wrappedValue)
    }

    /// diff プレビュー(- 変更前行 / + 置換後行)。置換後行は編集中のセレクタと説明で組み立てる
    /// (コメント無し行への説明追加も setTrailingComment の追記セマンティクスがそのまま効く)
    private var preview: (before: String, after: String)? {
        guard let original = source?.originalLine else { return nil }
        let quotedOld = "\"\(fix.oldSelector)\""
        var replaced = original.replacingOccurrences(
            of: quotedOld, with: "\"\(editedSelector.wrappedValue)\"")
        if let editedComment, commentValid {
            let newComment = editedComment.wrappedValue.trimmingCharacters(in: .whitespaces)
            if newComment != (source?.originalComment ?? "") {
                // 1 行だけのソースとして扱えば setTrailingComment をそのまま再利用できる
                replaced = (try? ScenarioSourceEditor.setTrailingComment(
                    inSource: replaced, line: 1, comment: newComment)) ?? replaced
            }
        }
        return (original.trimmingCharacters(in: .whitespaces),
                replaced.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: checked)
                .labelsHidden()
                .disabled(unavailable || !selectorValid || !commentValid)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(fix.scenarioID)
                    .font(.title3.weight(.semibold))
                Text("\(fix.file):\(fix.line)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("変更前")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    Text(fix.oldSelector)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("変更後")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    TextField("", text: editedSelector)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                if !selectorValid {
                    Text("⚠️ 適用できません(セレクタは空にできず、「\"」と改行は使えません)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if let editedComment {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("説明(変更前)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        if let originalComment = source?.originalComment {
                            Text(originalComment)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("(コメントなし)")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("説明(変更後)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        TextField("", text: editedComment)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }
                    if !commentValid {
                        Text("⚠️ 適用できません(説明に改行は使えません)")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                if let preview {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("- \(preview.before)")
                            .foregroundStyle(.red)
                        Text("+ \(preview.after)")
                            .foregroundStyle(.green)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                } else if unavailable {
                    Text("⚠️ 適用できません(ソースが変更されています)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if !fix.message.isEmpty {
                    Text(fix.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: editedSelector.wrappedValue) {
            // 不正な編集値の fix は適用対象から外す(有効に戻したら手でチェックし直す)
            if !selectorValid { checked.wrappedValue = false }
        }
        .onChange(of: editedComment?.wrappedValue) {
            if !commentValid { checked.wrappedValue = false }
        }
    }
}
