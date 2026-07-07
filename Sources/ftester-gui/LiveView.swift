// LiveView.swift
// ライブ操作タブ: スクリーンショットをクリックしてタップ、要素一覧、スワイプ、アプリ起動。
// 手動駆動コマンド(snapshot/tap/type/swipe)の GUI 版。

import SwiftUI
import FTCore

struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            screenshotPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            controlPane
                .frame(width: 400)
        }
        .padding()
    }

    // MARK: - 左: スクリーンショット(クリックでタップ)

    private var screenshotPane: some View {
        VStack {
            if let image = model.screenshot, let screen = model.screenSize {
                ScreenshotView(image: image, screen: screen) { x, y in
                    Task { await model.tap(x: x, y: y) }
                }
                Text("画像をクリックするとその位置をタップします")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("「更新」で画面を取得",
                                       systemImage: "iphone.gen3")
            }
        }
    }

    // MARK: - 右: 操作パネル

    private var controlPane: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("bundle ID / パッケージ名", text: $model.bundleID)
                    .textFieldStyle(.roundedBorder)
                Button("起動") { Task { await model.launchApp() } }
                Button("終了") { Task { await model.terminateApp() } }
            }

            HStack {
                Button {
                    Task { await model.refreshLive() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("u")
                if model.liveBusy { ProgressView().controlSize(.small) }
                Spacer()
                Group {
                    Button("↑") { Task { await model.swipe(.up) } }
                    Button("↓") { Task { await model.swipe(.down) } }
                    Button("←") { Task { await model.swipe(.left) } }
                    Button("→") { Task { await model.swipe(.right) } }
                }
                .help("スワイプ(↑=下へスクロール)")
            }

            if let error = model.liveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Text("要素一覧(クリックでタップ)")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(model.elements, id: \.ref) { element in
                Button {
                    Task { await model.tap(ref: element.ref) }
                } label: {
                    Text(elementLine(element))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func elementLine(_ element: ElementInfo) -> String {
        var parts = ["[\(element.ref)]", element.type]
        if let label = element.label, !label.isEmpty { parts.append("「\(label)」") }
        if let id = element.identifier, !id.isEmpty { parts.append("id=\(id)") }
        if let value = element.value, !value.isEmpty { parts.append("=\(value)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - クリック位置 → デバイス座標変換

struct ScreenshotView: View {
    let image: NSImage
    let screen: FTRect
    let onTap: (Double, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let fit = fitSize(in: geo.size)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fit.width, height: fit.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .gesture(SpatialTapGesture().onEnded { value in
                    guard fit.width > 0, fit.height > 0 else { return }
                    // 画像フレーム内のローカル座標 → デバイスのポイント座標
                    let x = Double(value.location.x) / fit.width * screen.width
                    let y = Double(value.location.y) / fit.height * screen.height
                    onTap(x, y)
                })
                .border(.separator)
        }
    }

    private func fitSize(in container: CGSize) -> CGSize {
        guard screen.width > 0, screen.height > 0 else { return container }
        let scale = min(container.width / screen.width, container.height / screen.height)
        return CGSize(width: screen.width * scale, height: screen.height * scale)
    }
}
