// DeviceMonitorGridView.swift
// デバイス画面のライブタイル一覧。実行タブでログと並べて使う。
// デバイスはクリックで選択(Shift+クリックで追加/解除、ドラッグ矩形で範囲選択)でき、
// 選択中は実行ログがそのデバイス分だけに絞り込まれる(AppModel.displayedLanes)。

import AppKit
import SwiftUI

/// 画面が未取得のタイルの縦横比(スマホ縦持ち想定)
private let phoneAspectRatio: CGFloat = 9 / 19.5

/// タイルの枠(グリッド座標系)を収集する。ドラッグ矩形との交差判定に使う
private struct TileFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct DeviceMonitorGridView: View {
    @Environment(AppModel.self) private var model
    @State private var showShutdownConfirm = false
    /// 可視タイルの枠(deviceKey → グリッド座標系の frame)
    @State private var tileFrames: [String: CGRect] = [:]
    /// ドラッグ中の選択矩形(グリッド座標系。nil = ドラッグしていない)
    @State private var rubberBand: CGRect?
    /// ドラッグ開始時点の選択(Shift/Cmd ドラッグはここに追加、通常ドラッグは空から)
    @State private var dragBaseSelection: Set<String>?
    /// グリッドのフォーカス(クリック・ドラッグで獲得)。フォーカス中だけ Cmd+A が
    /// 「デバイスを全選択」になる(それ以外では通常の Select All のまま)
    @FocusState private var gridFocused: Bool

    private static let gridSpace = "deviceMonitorGrid"
    /// 追加選択の修飾キー(Shift または Cmd)
    private static let extendModifiers: NSEvent.ModifierFlags = [.shift, .command]

    var body: some View {
        let center = model.monitor
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("デバイスモニター").font(.caption).foregroundStyle(.secondary)
                if center.monitoring, center.tileCount > 0 {
                    Text("\(center.tileCount) 画面")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !center.selectedDeviceKeys.isEmpty {
                    Text("選択 \(center.selectedDeviceKeys.count) 台")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("選択中のデバイス分だけ実行ログが表示されます"
                              + "(空クリックで解除、フォーカス中は Cmd+A で全選択)")
                }
                Spacer()
                Button {
                    Task { await model.bootAllDevices() }
                } label: {
                    if model.bootingDevices {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("デバイスを全て起動", systemImage: "power.circle")
                    }
                }
                .controlSize(.mini)
                .disabled(model.bootingDevices || model.shuttingDownSimulators || model.runningFlow)
                .help("マシンプロファイルに定義された全デバイスを起動します(負荷を見ながら最大2台同時・ヘッドレス。起動済みはスキップ)")
                Button {
                    showShutdownConfirm = true
                } label: {
                    if model.shuttingDownSimulators {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("デバイスを全て終了", systemImage: "power")
                    }
                }
                .controlSize(.mini)
                .disabled(model.runningFlow || model.shuttingDownSimulators)
                .help("全 iOS ブリッジを停止し、起動中のシミュレータと Android エミュレータをすべて終了します(Android 実機は対象外)")
                .confirmationDialog("起動中のデバイスを全て終了しますか?",
                                    isPresented: $showShutdownConfirm) {
                    Button("デバイスを全て終了", role: .destructive) {
                        Task { await model.shutdownAllSimulators() }
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("ftester ブリッジ停止 → simctl shutdown all → adb emu kill(emulator-* のみ)の順で実行します")
                }
                Toggle("", isOn: Binding(
                    get: { center.userEnabled },
                    set: { enabled in
                        center.userEnabled = enabled
                        if enabled {
                            center.start()
                        } else {
                            Task { await center.stop() }
                        }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("画面モニターの ON/OFF")
            }
            content
        }
        .padding(8)
        .task {
            center.start()
        }
        .onDisappear {
            Task { await center.stop() }
        }
    }

    @ViewBuilder
    private var content: some View {
        let center = model.monitor
        if !center.userEnabled {
            placeholder("モニターは OFF です")
        } else if !center.permissionGranted {
            permissionView
        } else if center.entries.isEmpty {
            placeholder("デバイスが見つかりません\n(マシンプロファイルにデバイスを定義するか、デバイスを起動してください)")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8,
                                             alignment: .top)],
                          spacing: 8) {
                    // タイルとカードは統合リスト(プロファイル定義順)で描画する。
                    // 同一デバイスの重複表示は MonitorEntry の合成時点で排除済み
                    ForEach(center.entries) { entry in
                        tile(for: entry)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor,
                                            lineWidth: center.selectedDeviceKeys
                                                .contains(entry.deviceKey) ? 2 : 0))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { handleTap(entry) }
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: TileFramesPreferenceKey.self,
                                    value: [entry.deviceKey:
                                                geo.frame(in: .named(Self.gridSpace))])
                            })
                    }
                }
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(TileFramesPreferenceKey.self) { frames in
                Task { @MainActor in tileFrames = frames }
            }
            .contentShape(Rectangle())
            // 何もない場所のクリックで選択解除(タイル上のクリックはタイル側が消費する)
            .onTapGesture {
                gridFocused = true
                center.selectedDeviceKeys = []
            }
            .gesture(rubberBandGesture)
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .overlay(alignment: .topLeading) {
                if let rect = rubberBand {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.7),
                                                    lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            // フォーカス中の控えめなインジケータ(この状態で Cmd+A が全選択になる)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(gridFocused ? 0.35 : 0), lineWidth: 1)
                    .allowsHitTesting(false))
            // Cmd+A = デバイスを全選択。グリッドがフォーカスを持つときだけ有効
            // (無効時はウィンドウのキーイクイバレントに掛からず、テキスト欄などの
            //  通常の「すべてを選択」がそのまま働く)
            .background(
                Button("デバイスを全選択") {
                    center.selectedDeviceKeys = Set(center.entries.map(\.deviceKey))
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!gridFocused)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true))
            if let error = center.lastError {
                Text("⚠️ \(error)").font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func tile(for entry: MonitorEntry) -> some View {
        switch entry.kind {
        case .stream(let streamer):
            StreamTileView(streamer: streamer)
        case .fallback(let tile):
            FallbackTileView(tile: tile)
        case .placeholder(let tile):
            PlaceholderTileView(tile: tile)
        }
    }

    /// クリック=単独選択(同じタイルの再クリックで解除)、Shift/Cmd+クリック=追加/解除
    private func handleTap(_ entry: MonitorEntry) {
        gridFocused = true
        let center = model.monitor
        let key = entry.deviceKey
        if !NSEvent.modifierFlags.intersection(Self.extendModifiers).isEmpty {
            if !center.selectedDeviceKeys.insert(key).inserted {
                center.selectedDeviceKeys.remove(key)
            }
        } else {
            center.selectedDeviceKeys = center.selectedDeviceKeys == [key] ? [] : [key]
        }
    }

    /// ドラッグ矩形による範囲選択。矩形に触れたタイルを選択する
    /// (Shift/Cmd を押しながらならドラッグ開始時の選択に追加)
    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                let center = model.monitor
                if dragBaseSelection == nil {
                    gridFocused = true
                    dragBaseSelection =
                        !NSEvent.modifierFlags.intersection(Self.extendModifiers).isEmpty
                        ? center.selectedDeviceKeys : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y))
                rubberBand = rect
                let hit = Set(tileFrames.filter { $0.value.intersects(rect) }.keys)
                center.selectedDeviceKeys = (dragBaseSelection ?? []).union(hit)
            }
            .onEnded { _ in
                rubberBand = nil
                dragBaseSelection = nil
            }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionView: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("画面収録の権限が必要です")
                .font(.caption)
            Text("swift run で起動した場合、権限はターミナル(Terminal / VS Code)に付与されます。システム設定 > プライバシーとセキュリティ > 画面収録 で許可後、ターミナルを再起動してください。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("画面収録を許可") { model.monitor.requestPermission() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// 起動済みデバイスタイル(SCK / フォールバック)の右クリックメニュー。
/// マシンプロファイルに対応するデバイスがあるときだけ「停止」を出す
/// (プロファイル外の手動起動デバイスはメニューなし)
@MainActor
@ViewBuilder
private func runningTileMenu(_ model: AppModel, label: String?) -> some View {
    if let device = model.machineDevice(forMonitorLabel: label) {
        Button("停止", role: .destructive) {
            Task { await model.shutdownDevice(device) }
        }
        .disabled(model.deviceOpsInProgress.contains(device.id) || model.runningFlow)
    }
}

/// SCK ストリームのタイル
private struct StreamTileView: View {
    @Environment(AppModel.self) private var model
    let streamer: WindowStreamer

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                freshnessDot
                if let label = streamer.portLabel {
                    Text(label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                Text(streamer.window.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let frame = streamer.latestFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let error = streamer.error {
                errorBox(error)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(phoneAspectRatio, contentMode: .fit)
            }
        }
        .padding(4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { runningTileMenu(model, label: streamer.portLabel) }
    }

    /// 鮮度ドット: 3秒以内にフレームあり=緑、それ以外=橙(最小化・停止の可能性)
    private var freshnessDot: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let fresh = streamer.lastFrameAt.map {
                context.date.timeIntervalSince($0) < 3
            } ?? false
            Circle()
                .fill(fresh ? .green : .orange)
                .frame(width: 7, height: 7)
                .help(fresh ? "ライブ" : "⏸ 更新停止中(ウィンドウ最小化?)")
        }
    }

    private func errorBox(_ message: String) -> some View {
        Text("⚠️ \(message)")
            .font(.caption2)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

/// 画面が取得できないデバイスのプレースホルダーカード
/// (マシンプロファイル定義のうち未起動 or ブリッジ未接続のもの)。
/// 右クリックでデバイス単体の起動ができる(停止は起動済みタイル側のメニュー)
private struct PlaceholderTileView: View {
    @Environment(AppModel.self) private var model
    let tile: PlaceholderTile

    private var booting: Bool { model.bootingDeviceIDs.contains(tile.id) }
    private var busy: Bool {
        model.deviceOpsInProgress.contains(tile.id) || booting
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(booting ? .blue : .secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .help(booting ? "起動中" : tile.status)
                Text(tile.name)
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.15), in: Capsule())
                Text(tile.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                    Text(booting ? "起動中" : "処理中...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: tile.platform == "ios" ? "iphone" : "smartphone")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(tile.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(phoneAspectRatio, contentMode: .fit)
            .background(.background.secondary.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .opacity(0.8)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            // 未起動カードの操作は「起動」のみ(「停止」は起動済みタイル側のメニュー)。
            // 起動済みだが画面が取れない中間状態も「起動」の再実行で回復する(冪等=
            // ブート済みならブリッジ接続のみ行い、タイル化すれば「停止」が出せるようになる)
            Button("起動") {
                Task { await model.bootDevice(tile) }
            }
            .disabled(busy)
        }
        .help("クリックで選択 / 右クリックで起動")
    }
}

/// ウィンドウ未検出デバイス用のフォールバックタイル(スクリーンショットポーリング。
/// ヘッドレス起動の Android エミュレータもここに表示される)
private struct FallbackTileView: View {
    @Environment(AppModel.self) private var model
    let tile: FallbackTile

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(.yellow).frame(width: 7, height: 7)
                    .help("ウィンドウ未検出(ヘッドレス起動など)のためスクリーンショットを2秒毎に取得中")
                Text(tile.label)
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.yellow.opacity(0.2), in: Capsule())
                Text(tile.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let image = tile.latestImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(phoneAspectRatio, contentMode: .fit)
            }
        }
        .padding(4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { runningTileMenu(model, label: tile.label) }
    }
}
