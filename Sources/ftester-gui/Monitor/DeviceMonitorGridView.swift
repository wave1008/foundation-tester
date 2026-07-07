// DeviceMonitorGridView.swift
// デバイス画面のライブタイル一覧。実行タブでログと並べて使う。

import SwiftUI

struct DeviceMonitorGridView: View {
    @Environment(AppModel.self) private var model

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
                Spacer()
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
        } else if center.tileCount == 0 {
            placeholder("デバイスウィンドウが見つかりません\n(Device Hub / エミュレータのウィンドウを表示してください)")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                          spacing: 8) {
                    ForEach(center.streamers) { streamer in
                        StreamTileView(streamer: streamer)
                    }
                    ForEach(center.fallbacks) { tile in
                        FallbackTileView(tile: tile)
                    }
                }
            }
            if let error = center.lastError {
                Text("⚠️ \(error)").font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
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

/// SCK ストリームのタイル
private struct StreamTileView: View {
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
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
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

/// ウィンドウ未検出ポート用のフォールバックタイル(/screenshot ポーリング)
private struct FallbackTileView: View {
    let tile: FallbackTile

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(.yellow).frame(width: 7, height: 7)
                    .help("ウィンドウ未検出のためスクリーンショットを2秒毎に取得中")
                Text("ios:\(String(tile.port))")
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
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}
