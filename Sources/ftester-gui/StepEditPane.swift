// StepEditPane.swift
// フローペインのステップ表の上部に置く編集用ペイン。選択中の行の内容(コマンド・説明・
// 関数独自パラメーター=timeout/duration/optional/direction/maxSwipes)を確認・編集し、
// 「適用」ボタンで 1 回の書換・1 回の再ビルドにまとめて反映する。既存のセル内インライン
// 編集・右クリックメニューはこのペインと独立に併存する。
//
// 設計判断:
// - ペインは Table のセルではない通常の View なので View ローカル @State で状態を持つ
//   (「Table セルは親 View の @State 変更では再描画されないことがある」既知のハマりは
//   NSTableView ベースの Table セル限定。ペインはセルではないので影響を受けない)
// - 高さは常に一定にする: 行の選択の有無・動詞の種類によらず同じ構造(ヘッダ+
//   コマンド/説明/パラメーターの 3 行+操作行)を描画する。カーソルキーで行を移動する
//   たびにペインが伸縮すると表が上下に揺れて使いにくい(ユーザーフィードバック)。
//   パラメーター行は内容(フィールド/「なし」/解釈不能)で高さが変わらないよう
//   固定高のコンテナに入れる
// - ダイアログは出さない。エラーはコマンド欄の上にオレンジ caption で表示する
//   (表の下では編集中に目に入らないというユーザーフィードバックによる配置)
// - パラメーターのフィールドは draft.commandText をライブ解釈した動詞で描画する。
//   動詞が変わったら(paramsVerb と不一致)ソースから読み取った現在値は捨て、新しい
//   動詞の既定値にリセットする(型の異なるパラメーターを引き継ぐ意味が無いため)
// - 幅は数値フィールド・方向 Picker とも固定幅にする。ペインに idealWidth を与えると
//   長いコマンド文字列でウィンドウが横に広がってしまう(ステップ表と同じ既知のハマり)

import FTDSL
import Foundation
import SwiftUI

/// 編集ペインのドラフト値。適用・取消の差分判定(dirty)はこれの Equatable 比較で行う
private struct StepEditDraft: Equatable {
    /// 表示表現(グリッドのコマンド列と同一形式。例: tap "ラベル")
    var commandText: String
    /// 行末コメント(row.comment ?? ""。生成文はプレースホルダとして表示するだけで値には含めない)
    var comment: String
    /// パラメータースキーマの name → UI 値
    var params: [String: String]
    /// params が属する動詞(StepCommandText.parse(commandText)?.verb。動詞変更の検出用)
    var paramsVerb: String

    static let empty = StepEditDraft(commandText: "", comment: "", params: [:], paramsVerb: "")
}

/// ステップ表の選択行を確認・編集するペイン。行未選択のときも同じレイアウトを
/// 無効状態で描画する(高さを一定に保つため)
struct StepEditPane: View {
    @Environment(AppModel.self) private var model
    let entry: AppModel.ScenarioEntry
    let rows: [AppModel.ScenarioStepRow]
    @Binding var editError: String?

    @State private var selectedRow: AppModel.ScenarioStepRow?
    /// プリフィル時にソースから読み取ったパラメーター現在値(nil = パラメーター編集不可)
    @State private var sourceParams: [String: String]?
    @State private var draft = StepEditDraft.empty
    @State private var original = StepEditDraft.empty
    @State private var applying = false

    /// プリフィルの再構築トリガ: シナリオが変わるか、一覧が再読込されるか、選択行が変わったら
    private struct PrefillKey: Equatable {
        let scenarioID: String
        let generation: Int
        let selection: Int?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let editError {
                Text("⚠️ \(editError)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            fieldGrid
            actionRow
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: PrefillKey(scenarioID: entry.info.id, generation: model.scenarioListGeneration,
                             selection: model.stepTableSelection)) {
            prefill()
        }
        // 動詞が変わったらパラメーターを新しい動詞の既定値にリセットする
        // (旧動詞のパラメーターを引き継ぐ意味が無いため)
        .onChange(of: draft.commandText) { _, newValue in
            let verb = StepCommandText.parse(newValue)?.verb ?? ""
            guard verb != draft.paramsVerb else { return }
            var reset: [String: String] = [:]
            for spec in StepCommandParams.specs(forVerb: verb) { reset[spec.name] = spec.defaultValue }
            draft.params = reset
            draft.paramsVerb = verb
        }
    }

    /// 選択行のパラメーター現在値を model から取り直し、ドラフトを作り直す
    private func prefill() {
        guard let selection = model.stepTableSelection,
              let row = rows.first(where: { $0.index == selection }) else {
            selectedRow = nil
            sourceParams = nil
            draft = .empty
            original = .empty
            applying = false
            return
        }
        let params = model.stepEditParams(row: row)
        let verb = StepCommandText.parse(row.command)?.verb ?? ""
        let built = StepEditDraft(commandText: row.command, comment: row.comment ?? "",
                                  params: params ?? [:], paramsVerb: verb)
        selectedRow = row
        sourceParams = params
        draft = built
        original = built
        applying = false
    }

    private var dirty: Bool { draft != original }

    /// commandText が未変更、または解釈可能な表示表現に変わっている場合に true。
    /// 編集不可行(ifCanSelect 等)は commandText が変わらないため常に true になり、
    /// 説明だけの編集を妨げない
    private var commandParseOK: Bool {
        draft.commandText == original.commandText || StepCommandText.parse(draft.commandText) != nil
    }

    /// draft.commandText をライブ解釈した動詞のパラメータースキーマ(空 = パラメーター無し)
    private var liveSpecs: [StepParamSpec] {
        guard let verb = StepCommandText.parse(draft.commandText)?.verb else { return [] }
        return StepCommandParams.specs(forVerb: verb)
    }

    /// パラメーターを編集可能な値として扱えるか。動詞を変更していれば(paramsVerb が
    /// プリフィル時から変わっていれば)常に既定値ベースで編集可能、動詞が同じままなら
    /// プリフィル時にソースから値を取り出せた(sourceParams != nil)場合のみ編集可能
    private var paramsAvailable: Bool {
        draft.paramsVerb != original.paramsVerb || sourceParams != nil
    }

    /// 行番号・scene・区分・ソース位置(未選択時は案内文)。高さを揃えるため
    /// どちらの状態でも同じ 1 行の HStack を描画する
    private var header: some View {
        HStack(spacing: 8) {
            if let row = selectedRow {
                Text("#\(row.index)").monospacedDigit()
                if let scene = row.scene {
                    Text("scene \(scene)").help(row.sceneTitle ?? "")
                }
                if !row.sectionLabel.isEmpty {
                    Text(row.sectionLabel).foregroundStyle(.secondary)
                }
                Text(sourceLabel(row))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("行を選択すると内容を確認・編集できます")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
    }

    private var fieldGrid: some View {
        // 編集不可の行(ifCanSelect 等)や未選択時もフィールド自体は描画して
        // disabled にする(読み取り専用 Text に切り替えると行の高さが変わるため)
        let rowSelected = selectedRow != nil
        let hasSource = selectedRow?.file != nil && selectedRow?.line != nil
        let commandEditable = selectedRow.map(AppModel.stepCommandEditable) ?? false
        let busy = applying || model.runningFlow
        return Grid(alignment: .leading, verticalSpacing: 6) {
            GridRow {
                Text("コマンド").font(.caption).foregroundStyle(.secondary)
                TextField("", text: draftBinding(\.commandText))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .disabled(!commandEditable || busy)
            }
            GridRow {
                Text("説明").font(.caption).foregroundStyle(.secondary)
                // コメントの無い行は生成文をプロンプト(淡色)で見せる。生成文も無ければ空
                TextField("", text: draftBinding(\.comment),
                          prompt: (selectedRow?.generatedComment).map(Text.init))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(!hasSource || busy)
            }
            GridRow {
                Text("パラメーター").font(.caption).foregroundStyle(.secondary)
                paramsContent(rowSelected: rowSelected)
                    // 内容(フィールド/キャプション/空)によらず高さを一定に保つ
                    .frame(height: 22, alignment: .leading)
            }
        }
    }

    /// パラメーター行の内容。未選択 = 空、スキーマ無しの動詞 = 「なし」、
    /// ソースを解釈できない行 = 案内文、それ以外 = 動詞に応じた入力フィールド
    @ViewBuilder
    private func paramsContent(rowSelected: Bool) -> some View {
        if !rowSelected {
            Text("")
        } else if liveSpecs.isEmpty {
            Text("なし")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if paramsAvailable {
            HStack(spacing: 12) {
                ForEach(liveSpecs, id: \.name) { spec in
                    paramField(spec)
                }
            }
        } else {
            Text("パラメーターを解釈できません(ソースを直接編集してください)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("適用") {
                guard let selectedRow else { return }
                Task { await apply(selectedRow) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedRow == nil || !dirty || applying
                      || model.runningFlow || !commandParseOK)

            Button("取消") {
                draft = original
                editError = nil  // ドラフトを元に戻したら適用エラーは無意味なので消す
            }
            .controlSize(.small)
            .disabled(!dirty || applying)

            if applying {
                ProgressView().controlSize(.small)
                Text("適用中(再ビルド)...").font(.caption).foregroundStyle(.secondary)
            } else if !commandParseOK {
                Text("コマンドを解釈できません").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// パラメーター 1 つ分の入力コントロール。数値は固定幅、方向はメニュー式 Picker で
    /// 幅を固定する(ペインの幅がコマンド文字列に引きずられないように)
    @ViewBuilder
    private func paramField(_ spec: StepParamSpec) -> some View {
        let disabled = applying || model.runningFlow
        switch spec.kind {
        case .int, .double:
            HStack(spacing: 4) {
                Text(spec.label).font(.caption)
                TextField("", text: paramBinding(spec.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(disabled)
            }
            .help(spec.help)
        case .bool:
            Toggle(spec.label, isOn: Binding(
                get: { (draft.params[spec.name] ?? spec.defaultValue) == "true" },
                set: { draft.params[spec.name] = $0 ? "true" : "false"
                       if editError != nil { editError = nil } }))
                .toggleStyle(.checkbox)
                .disabled(disabled)
                .help(spec.help)
        case .direction:
            HStack(spacing: 4) {
                Text(spec.label).font(.caption)
                Picker("", selection: paramBinding(spec.name)) {
                    Text("up").tag("up")
                    Text("down").tag("down")
                    Text("left").tag("left")
                    Text("right").tag("right")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
                .disabled(disabled)
            }
            .help(spec.help)
        }
    }

    /// draft のフィールドへの Binding。ユーザーの編集でエラー表示をクリアする
    /// (prefill のプログラム的な代入はこの Binding を通らないため、ビルド失敗
    /// メッセージが選択復元の再プリフィルで消えることはない)
    private func draftBinding<T>(_ keyPath: WritableKeyPath<StepEditDraft, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { draft[keyPath: keyPath] = $0
                       if editError != nil { editError = nil } })
    }

    private func paramBinding(_ name: String) -> Binding<String> {
        Binding(get: { draft.params[name] ?? "" },
                set: { draft.params[name] = $0
                       if editError != nil { editError = nil } })
    }

    /// ソース位置の表示("ファイル名:行"。フルパスは長すぎるためファイル名だけ)
    private func sourceLabel(_ row: AppModel.ScenarioStepRow) -> String {
        guard let file = row.file else { return "" }
        let name = (file as NSString).lastPathComponent
        return row.line.map { "\(name):\($0)" } ?? name
    }

    /// 「適用」: コマンド・パラメーター・説明を 1 回の書換にまとめて反映する。
    /// params/comment は未変更なら nil を渡し、それぞれの変更なしパスに委ねる
    /// (params 未変更 = リテラル置換のみで書式を保存)
    private func apply(_ row: AppModel.ScenarioStepRow) async {
        editError = nil  // 再適用が成功したとき前回のエラーが残らないように(失敗すれば入り直す)
        applying = true
        let message = await model.applyStepEdit(
            row: row,
            display: draft.commandText,
            params: (draft.params == original.params && draft.paramsVerb == original.paramsVerb)
                ? nil : draft.params,
            comment: draft.comment == original.comment ? nil : draft.comment)
        applying = false
        if let message { editError = message }
    }
}
