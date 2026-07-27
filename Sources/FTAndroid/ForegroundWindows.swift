// 対象アプリより手前に出ている「別プロセスの window」の検出。
// アプリの a11y ツリーには他プロセスの window が出ないため、システムダイアログや IME の案内が
// アプリを覆っていても**スナップショット上は正常に見え、tap は成功扱いで返る**
// (実害: Gboard のスタイラス案内が送信ボタンを覆い、05_テキスト入力 が間欠失敗した。
// AndroidBridge.disableStylusHandwriting 参照)。失敗時にこれを添えて再調査を不要にする。

import Foundation
import FTCore

public enum AndroidForegroundWindows {

    /// 常に可視で、操作の邪魔をしない画面装飾。報告しても雑音にしかならないので除く
    /// (前方一致で判定。`NavigationBar0` のような連番付きがあるため)
    static let chromePrefixes = [
        "StatusBar", "Taskbar", "NavigationBar", "ScreenDecorOverlay",
        "EdgeBackGestureHandler", "ShellDropTarget", "ImageWallpaper",
    ]

    /// `dumpsys window windows` の出力から、**対象アプリの window より手前**にある
    /// 可視の別 window 名を z 順(手前が先)で返す。アプリの window が見つからなければ空
    /// (判定できないときは黙る = 誤った断定をしない)
    public static func overlaying(package: String, dumpsys: String) -> [String] {
        var names: [String] = []
        var visibility: [Bool] = []
        var current: String?
        for line in dumpsys.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Window #"), let name = windowName(text) {
                // 直前のブロックが isVisible を持たなかった場合に列がずれないよう埋める
                if current != nil, names.count > visibility.count { visibility.append(false) }
                names.append(name)
                current = name
            } else if current != nil, text.hasPrefix("isVisible="),
                      names.count > visibility.count {
                visibility.append(text == "isVisible=true")
            }
        }
        if names.count > visibility.count { visibility.append(false) }

        guard let appIndex = names.indices.first(where: {
            visibility[$0] && names[$0].hasPrefix("\(package)/")
        }) else { return [] }

        return names.indices.prefix(upTo: appIndex).compactMap { index in
            guard visibility[index] else { return nil }
            let name = names[index]
            guard !name.hasPrefix("\(package)/") else { return nil }
            guard !chromePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            return name
        }
    }

    /// `Window #7 Window{b9b01a8 u0 InputMethod}:` → `InputMethod`
    static func windowName(_ line: String) -> String? {
        guard let braceIndex = line.firstIndex(of: "{"),
              let closeIndex = line.lastIndex(of: "}") , braceIndex < closeIndex else { return nil }
        let inner = line[line.index(after: braceIndex)..<closeIndex]
        // `<hash> u<user> <名前>` の3つ目以降(名前に空白は入らない)
        let parts = inner.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        return String(parts[2])
    }

    /// 実機/エミュレータへ問い合わせる。adb が無い・失敗した場合は空(失敗診断の付加情報なので非致命)
    public static func query(package: String, serial: String) -> [String] {
        guard let adb = try? AndroidDriver.findADB(),
              let output = try? Shell.run([adb, "-s", serial, "shell", "dumpsys", "window", "windows"],
                                          timeout: 10).output else { return [] }
        return overlaying(package: package, dumpsys: output)
    }
}
