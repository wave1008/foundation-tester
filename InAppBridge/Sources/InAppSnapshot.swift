// アプリ内アクセシビリティツリー走査 → ElementInfo(BridgeDTO と共有形式)。
// Runner/BridgeRouter の collect/shouldInclude/makeInfo(XCUITest 版)と「同じ出力」を目指す
// プロセス内実装。XCUITest は testmanagerd 経由で AX ツリーを IPC 取得するが、こちらは
// UIKit の UIAccessibility API を直接読む(IPC ゼロ)。フィルタ規則は BridgeRouter と揃える
// (契約=どの要素を返すか。ずれると FM への画面像が XCUITest 版と食い違う)。

import UIKit

enum InAppSnapshot {

    /// 収集結果。frames は ref → 画面座標フレーム(tap のヒットテスト用)。
    struct Result {
        var screen: FTRect
        var elements: [ElementInfo]
        var frames: [Int: CGRect]
        var truncated: Int
    }

    static func capture(window: UIWindow) -> Result {
        let screen = window.bounds
        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var truncated = 0
        collect(window, depth: 0, screen: screen,
                elements: &elements, frames: &frames, truncated: &truncated)
        return Result(
            screen: FTRect(x: screen.origin.x, y: screen.origin.y,
                           width: screen.width, height: screen.height),
            elements: elements, frames: frames, truncated: truncated)
    }

    private static func collect(_ node: NSObject, depth: Int, screen: CGRect,
                                elements: inout [ElementInfo], frames: inout [Int: CGRect],
                                truncated: inout Int) {
        // 非表示サブツリーは丸ごと除外
        if let view = node as? UIView, view.isHidden || view.alpha < 0.01
            || view.accessibilityElementsHidden { return }

        let type = elementType(node)
        // キーボードのキーは大量に写り込むため除外(入力は /type が担うので情報として不要)
        if type == .keyboardKey { return }

        if let info = shouldInclude(node, type: type, screen: screen) {
            if elements.count < BridgeAPI.maxSnapshotElements {
                let ref = elements.count + 1
                frames[ref] = info.frame
                elements.append(makeInfo(node, type: type, ref: ref, depth: depth, frame: info.frame))
            } else {
                truncated += 1
            }
        }

        // AX 子の探索: isAccessibilityElement な要素は葉として扱いサブツリーに降りない。
        // それ以外は accessibilityElements(あれば)を、無ければ subviews を辿る。
        if let view = node as? UIView, view.isAccessibilityElement { return }
        let children = axChildren(node)
        for child in children {
            collect(child, depth: depth + 1, screen: screen,
                    elements: &elements, frames: &frames, truncated: &truncated)
        }
    }

    private static func axChildren(_ node: NSObject) -> [NSObject] {
        if let els = node.accessibilityElements as? [NSObject], !els.isEmpty { return els }
        if let view = node as? UIView { return view.subviews }
        return []
    }

    private struct Included { let frame: CGRect }

    private static func shouldInclude(_ node: NSObject, type: UIKitType, screen: CGRect) -> Included? {
        let frame = axFrame(node)
        guard frame.width >= 2, frame.height >= 2 else { return nil }
        guard screen.isEmpty || frame.intersects(screen) else { return nil }

        // 画面の大半を覆う Other コンテナは除外(誤タップ誘発。BridgeRouter と同じ)
        if type == .other {
            let screenArea = screen.width * screen.height
            if screenArea > 0, (frame.width * frame.height) / screenArea > 0.85 { return nil }
        }

        let hasText = !(axIdentifier(node) ?? "").isEmpty
            || !(node.accessibilityLabel ?? "").isEmpty
            || !(node.accessibilityValue ?? "").isEmpty

        switch type {
        case .button, .textField, .secureTextField, .textView, .adjustable, .cell,
             .link, .searchField, .picker:
            return Included(frame: frame)
        case .staticText, .image:
            return hasText ? Included(frame: frame) : nil
        case .navigationBar, .tabBar, .alert:
            return Included(frame: frame)
        case .keyboardKey:
            return nil
        case .other:
            return (axIdentifier(node) ?? "").isEmpty ? nil : Included(frame: frame)
        }
    }

    // accessibilityIdentifier は UIAccessibilityIdentification プロトコル側(NSObject には無い)
    private static func axIdentifier(_ node: NSObject) -> String? {
        (node as? UIAccessibilityIdentification)?.accessibilityIdentifier
    }

    private static func makeInfo(_ node: NSObject, type: UIKitType, ref: Int, depth: Int,
                                 frame: CGRect) -> ElementInfo {
        let traits = node.accessibilityTraits
        let enabled = !traits.contains(.notEnabled)
        let id = axIdentifier(node)
        let label = node.accessibilityLabel
        let value = node.accessibilityValue
        return ElementInfo(
            ref: ref,
            type: typeName(type),
            identifier: (id?.isEmpty ?? true) ? nil : id,
            label: (label?.isEmpty ?? true) ? nil : label,
            value: (value?.isEmpty ?? true) ? nil : value,
            placeholder: (node as? UITextField)?.placeholder,
            enabled: enabled,
            frame: FTRect(x: frame.origin.x, y: frame.origin.y,
                          width: frame.width, height: frame.height),
            depth: depth)
    }

    private static func axFrame(_ node: NSObject) -> CGRect {
        // UIView は view ジオメトリを window 座標へ変換する(accessibilityFrame は AX 未活性時に
        // zero を返すことがあり、フィルタで全要素が落ちる)。合成 AX 要素は accessibilityFrame。
        if let view = node as? UIView {
            return view.convert(view.bounds, to: nil)
        }
        return node.accessibilityFrame
    }

    // MARK: - 型判定(UIAccessibilityTraits + クラス → BridgeDTO の型名)

    enum UIKitType {
        case button, staticText, textField, secureTextField, textView, image, adjustable
        case cell, link, searchField, picker, navigationBar, tabBar, alert, keyboardKey, other
    }

    private static func elementType(_ node: NSObject) -> UIKitType {
        if let tf = node as? UITextField { return tf.isSecureTextEntry ? .secureTextField : .textField }
        if node is UITextView { return .textView }
        let t = node.accessibilityTraits
        if t.contains(.keyboardKey) { return .keyboardKey }
        if t.contains(.searchField) { return .searchField }
        if t.contains(.link) { return .link }
        if t.contains(.button) { return .button }
        if t.contains(.image) { return .image }
        if t.contains(.adjustable) { return .adjustable }
        if t.contains(.staticText) || t.contains(.header) { return .staticText }
        if node is UINavigationBar { return .navigationBar }
        if node is UITabBar { return .tabBar }
        return .other
    }

    private static func typeName(_ type: UIKitType) -> String {
        switch type {
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .image: return "Image"
        case .adjustable: return "Slider"
        case .cell: return "Cell"
        case .link: return "Link"
        case .searchField: return "SearchField"
        case .picker: return "Picker"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .alert: return "Alert"
        case .keyboardKey: return "KeyboardKey"
        case .other: return "Other"
        }
    }
}
