// UIテスト(ブリッジ)の器になるだけの空アプリ。

import SwiftUI

@main
struct FTesterRunnerApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                Text("FTester Runner Host")
                    .font(.headline)
                Text("このアプリ自体は何もしません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
