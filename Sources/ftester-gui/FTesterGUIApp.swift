// FTesterGUIApp.swift
// ftester の GUI(SwiftUI macOS アプリ)。SwiftPM 実行ターゲットとして起動する:
//   swift run ftester-gui
// リポジトリルートから起動すること(flows/ を相対パスで読むため)。

import AppKit
import SwiftUI

@main
struct FTesterGUIApp: App {
    @State private var model = AppModel()

    init() {
        // SPM 実行バイナリからでも通常アプリとして前面に出す
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("ftester Studio") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
    }
}
