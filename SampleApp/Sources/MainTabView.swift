import SwiftUI

struct MainTabView: View {
    let onLogout: () -> Void

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("ホーム", systemImage: "house") }
                .accessibilityIdentifier("tab_home")

            SettingsView(onLogout: onLogout)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .accessibilityIdentifier("tab_settings")
        }
    }
}

struct HomeView: View {
    private let items = ["りんご", "バナナ", "オレンジ", "ぶどう", "メロン", "いちご", "キウイ", "マンゴー",
                         "もも", "なし", "かき", "すいか", "レモン", "ライム", "さくらんぼ", "ブルーベリー",
                         "パイナップル", "ざくろ", "いちじく", "アボカド", "グレープフルーツ", "ドリアン",
                         "ラズベリー", "クランベリー"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("ようこそ")
                    .font(.title2.bold())
                    .padding(.horizontal)
                    .accessibilityIdentifier("welcome_text")

                List(items, id: \.self) { item in
                    HStack {
                        Text(item)
                        Spacer()
                        Text("¥100")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("item_\(item)")
                }
                .accessibilityIdentifier("item_list")
            }
            .navigationTitle("ホーム")
        }
    }
}

struct SettingsView: View {
    let onLogout: () -> Void

    @State private var notificationsEnabled = true
    @State private var darkModeEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section("一般") {
                    Toggle("通知", isOn: $notificationsEnabled)
                        .accessibilityIdentifier("notif_toggle")
                    Toggle("ダークモード", isOn: $darkModeEnabled)
                        .accessibilityIdentifier("darkmode_toggle")
                }
                Section {
                    Button("ログアウト", role: .destructive, action: onLogout)
                        .accessibilityIdentifier("logout_btn")
                }
            }
            .navigationTitle("設定")
        }
    }
}
