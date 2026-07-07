// ExploreView.swift
// FM探索タブ: 自然言語のゴールから ExplorerAgent がテストフローを生成する。

import SwiftUI

struct ExploreView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            if !model.fmReport.available {
                Label(model.fmReport.detail, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("対象アプリ")
                    TextField("bundle ID / パッケージ名", text: $model.exploreBundleID)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("テスト目標")
                    TextField("例: test@example.com でログインし、「ようこそ」が表示されることを確認する",
                              text: $model.exploreGoal, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("最大ステップ")
                    Stepper("\(model.exploreMaxSteps)", value: $model.exploreMaxSteps, in: 5...50)
                        .frame(width: 120, alignment: .leading)
                }
            }

            HStack {
                Button {
                    model.startExplore()
                } label: {
                    Label("探索開始", systemImage: "sparkles")
                }
                .disabled(model.exploring || !model.fmReport.available
                          || model.exploreGoal.isEmpty || model.exploreBundleID.isEmpty)

                if model.exploring {
                    Button("中断") { model.cancelExplore() }
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("確認したい文言は「」で囲むと、停滞時にコード側検証で拾われます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.exploreLog.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(.background.secondary)
                .onChange(of: model.exploreLog.count) {
                    proxy.scrollTo("bottom")
                }
            }
        }
        .padding()
    }
}
