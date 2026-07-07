// ContentView.swift
// メイン画面: サイドバー(フロー一覧)+ 3タブ(フロー実行 / ライブ操作 / FM探索)

import SwiftUI
import FTCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("フロー実行").tag(0)
                    Text("ライブ操作").tag(1)
                    Text("FM探索").tag(2)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch tab {
                case 0: RunView()
                case 1: LiveView()
                default: ExploreView()
                }
            }
        }
        .toolbar { toolbarContent }
        .task {
            model.refreshFlows()
            await model.checkConnection()
        }
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(selection: $model.selectedFlowID) {
            Section("フロー(flows/)") {
                ForEach(model.flows) { entry in
                    HStack(spacing: 8) {
                        stateIcon(entry.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.flow.name)
                                .lineLimit(1)
                            Text("\(entry.flow.platform ?? "ios") ・ \(entry.flow.steps.count) steps"
                                 + (entry.flow.dirty == true ? " ・ dirty" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.url)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshFlows()
                } label: {
                    Label("再読込", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await model.runAll() }
                } label: {
                    Label("全実行", systemImage: "play.square.stack")
                }
                .disabled(model.runningFlow || model.flows.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            Picker("Platform", selection: $model.platform) {
                Text("iOS").tag("ios")
                Text("Android").tag("android")
            }
            .pickerStyle(.segmented)

            if model.platform == "ios" {
                TextField("port", text: $model.portText)
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("serial(任意)", text: $model.serial)
                    .frame(width: 120)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                Task { await model.checkConnection() }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.connected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(model.connectionStatus)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .help("クリックで再確認")
        }
    }

    @ViewBuilder
    func stateIcon(_ state: AppModel.RunState) -> some View {
        switch state {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "play.circle.fill").foregroundStyle(.blue)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - フロー実行タブ

struct RunView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                if let entry = model.selectedEntry {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.flow.name).font(.headline).lineLimit(2)
                            Text("\(entry.flow.app) [\(entry.flow.platform ?? "ios")]")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("自己修復(--heal)", isOn: $model.heal)
                            .toggleStyle(.checkbox)
                        Button {
                            Task { await model.runSelected() }
                        } label: {
                            Label("実行", systemImage: "play.fill")
                        }
                        .keyboardShortcut("r")
                        .disabled(model.runningFlow)
                    }
                    List(Array(entry.flow.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step.summary)")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                } else {
                    ContentUnavailableView("フローを選択してください",
                                           systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            .frame(minHeight: 200)

            logView
                .frame(minHeight: 140)
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("実行ログ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("クリア") { model.runLog = [] }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.runLog.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(.background.secondary)
                .onChange(of: model.runLog.count) {
                    proxy.scrollTo("bottom")
                }
            }
        }
        .padding([.horizontal, .bottom])
    }
}
