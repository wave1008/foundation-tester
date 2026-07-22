import Foundation

// 永続化キーは "launch_count" / "auto_dialog" / "heal_schema_v1" の3つのみ(docs/ui-contract.md §永続化する値)。
// launchApp はアプリのデータを消さないため、これ以外を永続化するとシナリオの前提が崩れる。
enum Prefs {
    static func getInt(_ key: String, _ def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? def
    }
    static func setInt(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: key)
    }
    static func getBool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    static func setBool(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// counted ガードは SwiftUI の body 再評価による二重加算を防ぐ。App の init から1回だけ呼ばれる前提。
final class LaunchCounter: ObservableObject {
    static let shared = LaunchCounter()
    @Published private(set) var value = 0
    private var counted = false

    func ensureCounted() {
        guard !counted else { return }
        counted = true
        value = Prefs.getInt("launch_count", 0) + 1
        Prefs.setInt("launch_count", value)
    }

    func reset() {
        value = 1
        Prefs.setInt("launch_count", 1)
    }
}

// remember 相当ではなく単一インスタンス: relaunch 検証は「画面離脱後も session が保持され、
// relaunch でのみ 0 に戻る」ことが要件。
final class SessionCounter: ObservableObject {
    static let shared = SessionCounter()
    @Published var value = 0
}
