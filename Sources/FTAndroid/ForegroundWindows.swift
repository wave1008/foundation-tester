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
        let blocks = windowBlocks(dumpsys)
        guard let appIndex = blocks.indices.first(where: {
            blocks[$0].visible && blocks[$0].name.hasPrefix("\(package)/")
        }) else { return [] }

        return blocks.indices.prefix(upTo: appIndex).compactMap { index in
            guard blocks[index].visible else { return nil }
            let name = blocks[index].name
            guard !name.hasPrefix("\(package)/") else { return nil }
            guard !chromePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            return name
        }
    }

    /// `dumpsys window windows` にソフトキーボード(IME)の window が**表示中**で存在するか。
    /// AndroidDriver.snapshot() の keyboardShown 判定用(オンデバイスのブリッジは別プロセスの
    /// window を a11y ツリーから見れないため、ホスト側でここを叩いて補う)。
    /// isVisible=false の居残り window(閉じかけ等)は false 扱い(overlaying と同じ可視性規約)
    public static func keyboardVisible(dumpsys: String) -> Bool {
        windowBlocks(dumpsys).contains { $0.visible && $0.name.hasPrefix("InputMethod") }
    }

    /// `Window #N Window{... 名前}:` ブロックを (名前, isVisible) の並び(z 順)に分解する。
    /// overlaying / keyboardVisible の共通パーサ(可視性判定はここ1箇所)
    private static func windowBlocks(_ dumpsys: String) -> [(name: String, visible: Bool)] {
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
        return zip(names, visibility).map { (name: $0, visible: $1) }
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

    /// 最前面のアプリの package 名を返す。DSL の appIs 用。
    /// 本線は z 順の window リスト: **可視(isVisible=true)のアプリ窓は前面の1つだけ**で、
    /// 背面アプリ・ランチャーは isVisible=false、システム装飾・IME は名前に `/` を含まない
    /// (Android 15 エミュレータで実測)。`mCurrentFocus=` 行があれば優先するが、
    /// Android 15 の `dumpsys window windows` にはこの行が出ない(実測。行前提の実装は
    /// 常に nil になり appIs が必ずタイムアウトした)。
    /// どちらでも取れなければ nil(不明。判定できないときは黙る=overlaying と同じ規約)
    public static func topmostAppPackage(dumpsys: String) -> String? {
        if let line = dumpsys.split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("mCurrentFocus=") }),
           let name = windowName(line),
           let slashIndex = name.firstIndex(of: "/") {
            return String(name[..<slashIndex])
        }
        for block in windowBlocks(dumpsys) where block.visible {
            if let slashIndex = block.name.firstIndex(of: "/") {
                return String(block.name[..<slashIndex])
            }
        }
        return nil
    }

    /// 実機/エミュレータへ問い合わせる。adb が無い・失敗した場合は空(失敗診断の付加情報なので非致命)
    public static func query(package: String, serial: String) -> [String] {
        guard let adb = try? AndroidDriver.findADB(),
              let output = try? Shell.run([adb, "-s", serial, "shell", "dumpsys", "window", "windows"],
                                          timeout: 10).output else { return [] }
        return overlaying(package: package, dumpsys: output)
    }
}
