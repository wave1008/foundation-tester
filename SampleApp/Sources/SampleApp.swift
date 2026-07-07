// SampleApp — foundation-tester の検証用テスト対象アプリ。
// ログイン(test@example.com / password123)→ ホーム/設定タブ。
// 全ての操作対象に accessibilityIdentifier を付与している。

import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var loggedIn = false

    var body: some View {
        if loggedIn {
            MainTabView(onLogout: { loggedIn = false })
        } else {
            LoginView(onSuccess: { loggedIn = true })
        }
    }
}
