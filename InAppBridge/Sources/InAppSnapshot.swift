// アプリ内アクセシビリティツリー走査 → ElementInfo(BridgeDTO と共有形式)。
// Runner/BridgeRouter の collect/shouldInclude/makeInfo(XCUITest 版)と「同じ出力」を目指す
// プロセス内実装。XCUITest は testmanagerd 経由で AX ツリーを IPC 取得するが、こちらは
// UIKit の UIAccessibility API を直接読む(IPC ゼロ)。フィルタ規則は BridgeRouter と揃える
// (契約=どの要素を返すか。ずれると FM への画面像が XCUITest 版と食い違う)。

import UIKit

enum InAppSnapshot {

    /// 収集結果。frames は ref → 画面座標フレーム(tap の座標解決用)、
    /// nodes は ref → 走査した AX 要素/ビュー(accessibilityActivate 等の直接操作用)。
    struct Result {
        var screen: FTRect
        var elements: [ElementInfo]
        var frames: [Int: CGRect]
        var nodes: [Int: NSObject]
        var truncated: Int
    }

    static func capture(window: UIWindow) -> Result {
        let screen = window.bounds
        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var nodes: [Int: NSObject] = [:]
        var truncated = 0
        // 同じオブジェクトが2経路から届くことがある(Compose iOS の interop は WKWebView を
        // accessibilityElements と subviews の両方から見せ、同じ WebView が2度出た。2026-07-29 実測)。
        // 重複すると同じラベルが並んでセレクタが曖昧になり、DOM も2回読むことになる
        var visited = Set<ObjectIdentifier>()
        collect(window, depth: 0, screen: screen, visited: &visited,
                elements: &elements, frames: &frames, nodes: &nodes, truncated: &truncated)
        return Result(
            screen: FTRect(x: screen.origin.x, y: screen.origin.y,
                           width: screen.width, height: screen.height),
            elements: elements, frames: frames, nodes: nodes, truncated: truncated)
    }

    private static func collect(_ node: NSObject, depth: Int, screen: CGRect,
                                visited: inout Set<ObjectIdentifier>,
                                elements: inout [ElementInfo], frames: inout [Int: CGRect],
                                nodes: inout [Int: NSObject], truncated: inout Int) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        // 非表示サブツリーは丸ごと除外
        if let view = node as? UIView, view.isHidden || view.alpha < 0.01
            || view.accessibilityElementsHidden { return }

        let type = elementType(node)
        // キーボードのキーは大量に写り込むため除外(入力は /type が担うので情報として不要)。
        // **キーボードの表示判定はここではできない**(キーウィンドウの外に載るため。
        // 判定は InAppBridge.keyboardWindowVisible)
        if type == .keyboardKey { return }

        if let info = shouldInclude(node, type: type, screen: screen) {
            if elements.count < BridgeAPI.maxSnapshotElements {
                let ref = elements.count + 1
                frames[ref] = info.frame
                nodes[ref] = node
                elements.append(makeInfo(node, type: type, ref: ref, depth: depth, frame: info.frame))
            } else {
                truncated += 1
            }
        }

        // WKWebView の内部(WKScrollView/WKContentView)は AX を別プロセスが持つため走査しても
        // 何も採れない。降りるだけ無駄なので葉として閉じる(中身は InAppWebViewDOM が DOM から読む)
        if type == .webView { return }

        // AX 子の探索: isAccessibilityElement な要素は葉として扱いサブツリーに降りない。
        // それ以外は accessibilityElements(あれば)を、無ければ subviews を辿る。
        if let view = node as? UIView, view.isAccessibilityElement { return }
        let children = axChildren(node)
        for child in children {
            collect(child, depth: depth + 1, screen: screen, visited: &visited,
                    elements: &elements, frames: &frames, nodes: &nodes, truncated: &truncated)
        }
    }

    private static func axChildren(_ node: NSObject) -> [NSObject] {
        if let els = node.accessibilityElements as? [NSObject], !els.isEmpty { return els }
        if let view = node as? UIView { return view.subviews }
        // **非 UIView 限定**: Flutter の SemanticsObjectContainer は accessibilityElements を
        // 実装せず、旧式の indexed UIAccessibilityContainer API(accessibilityElementCount /
        // accessibilityElement(at:))だけを実装する。これを辿らないと FlutterView の
        // 直下(コンテナ)で走査が止まり snapshot が 0 要素になる(2026-07-23 実測)。
        // UIView に適用してはいけない: UITableView 等も indexed API を実装しており、
        // subviews 走査(UITableViewCell を拾う従来経路)を乗っ取って `.Cell` が消える退行を
        // 実際に起こした。上限は暴走ガード(通常の Flutter コンテナは子1〜数十個)。
        let count = node.accessibilityElementCount()
        if count > 0, count != NSNotFound, count < 10_000 {
            var out: [NSObject] = []
            for i in 0..<count {
                if let el = node.accessibilityElement(at: i) as? NSObject { out.append(el) }
            }
            if !out.isEmpty { return out }
        }
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
        case .button, .toggle, .textField, .secureTextField, .textView, .adjustable, .cell,
             .link, .searchField, .picker:
            return Included(frame: frame)
        case .staticText, .image:
            return hasText ? Included(frame: frame) : nil
        case .navigationBar, .tabBar, .alert, .webView:
            return Included(frame: frame)
        case .keyboardKey:
            return nil
        case .other:
            return (axIdentifier(node) ?? "").isEmpty ? nil : Included(frame: frame)
        }
    }

    // SwiftUI の AccessibilityNode/UIKitTextField は UIAccessibilityIdentification 準拠を
    // 宣言しないため as? では取れない。セレクタ直接呼び出し(FTAccessibilityIdentifier)で取る。
    private static func axIdentifier(_ node: NSObject) -> String? {
        FTAccessibilityIdentifier(node)
    }

    private static func makeInfo(_ node: NSObject, type: UIKitType, ref: Int, depth: Int,
                                 frame: CGRect) -> ElementInfo {
        let traits = node.accessibilityTraits
        let enabled = !traits.contains(.notEnabled)
        let id = axIdentifier(node)
        let label = node.accessibilityLabel
        return ElementInfo(
            ref: ref,
            type: typeName(type),
            identifier: (id?.isEmpty ?? true) ? nil : id,
            label: (label?.isEmpty ?? true) ? nil : label,
            value: valueString(node),
            placeholder: (node as? UITextField)?.placeholder,
            enabled: enabled,
            frame: FTRect(x: frame.origin.x, y: frame.origin.y,
                          width: frame.width, height: frame.height),
            depth: depth,
            // XCUITest 版と同じ経路(UIAccessibilityTraits.selected)。false は送らない
            checked: traits.contains(.selected) ? true : nil,
            // clearInput 事後検証用(ElementInfo.focused 参照)。true のときだけ送る
            focused: (node as? UIResponder)?.isFirstResponder == true ? true : nil,
            // スクロールできる容器か(scrollFrame の空振り検出用)。**UIKit/SwiftUI でだけ分かる** ——
            // Compose/Flutter は自前描画で UIScrollView を持たず、AX の scroll 可否は
            // 呼ぶと実際にスクロールしてしまうので非破壊に判定できない(false は送らない)
            scrollable: node is UIScrollView ? true : nil)
    }

    // 空の UITextField は accessibilityValue が placeholder を返すため value に漏れる。
    // 実テキストが空なら value なし(placeholder は placeholder フィールドで返す)。
    // 非空の SecureTextField は accessibilityValue がマスク(•••)を返すので実テキストは晒さない。
    private static func valueString(_ node: NSObject) -> String? {
        if let tf = node as? UITextField, (tf.text ?? "").isEmpty { return nil }
        let value = node.accessibilityValue
        return (value?.isEmpty ?? true) ? nil : value
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
        /// switch は予約語なので toggle と命名(型名は "Switch" = XCUITest 版と同じ語彙)
        case toggle
        /// WKWebView。**a11y ツリー経由では中身が一切見えない**(Web コンテンツの AX は別プロセスが
        /// 提供する。2026-07-29 実測)。中身は InAppWebViewDOM が DOM から読んでここへ差し込む。
        /// コンテナ自体は識別子が無くても必ず出す(スコープ起点 `.webView` + ホスト側の委譲判定)
        case webView
    }

    /// WebKit をリンクせずに WKWebView を判定する(dylib の依存を増やさない)。
    /// クラス取得は1回だけ(走査で全ノードに当たるため)
    private static let webViewClass: AnyClass? = NSClassFromString("WKWebView")

    /// テキスト入力を表す非公開 trait(`1<<18`)。公開 API に相当するものが無く、
    /// UIKit の UITextField/UITextView と Compose/Flutter の合成 AX 要素が共通で立てる
    /// (2026-08-06 に iOS 27.0 の Simulator で実測)。`elementType` の宣言参照
    private static let textEntryTrait = UIAccessibilityTraits(rawValue: 1 << 18)

    private static func elementType(_ node: NSObject) -> UIKitType {
        // trait 判定より先に置く: WKWebView は内部に別の trait を持つ子を抱えており、
        // 後ろに置くと other に落ちてホストが webview 画面だと気付けない
        if let webViewClass, node.isKind(of: webViewClass) { return .webView }
        if let tf = node as? UITextField { return tf.isSecureTextEntry ? .secureTextField : .textField }
        if node is UITextView { return .textView }
        // セルは trait を持たないため、クラスで判定しないと .other に落ちて `.Cell` セレクタが
        // xcuitest エンジンとだけ食い違う(2026-07-23 に TestProjects/E2E-iOS で実測)。
        // trait 判定より先に置く: セル内のボタン trait に引きずられて Button にしないため。
        if node is UITableViewCell || node is UICollectionViewCell { return .cell }
        let t = node.accessibilityTraits
        // スイッチは `.button` も併せ持つので **button 判定より先**に見る。UIKit/SwiftUI/Compose とも
        // 実測で traits = .button|.toggleButton(0x20000000000001)だった(2026-07-27・E2E-iOS と E2E)。
        // これが無いと in-app だけ型が Button になり、`.switch` / `:rightSwitch` が xcuitest と食い違う
        // (XCUITest は elementType が switch を直接返すため気づきにくい)
        if #available(iOS 17.0, *), t.contains(.toggleButton) { return .toggle }
        if node is UISwitch { return .toggle }
        if t.contains(.keyboardKey) { return .keyboardKey }
        if t.contains(.searchField) { return .searchField }
        if t.contains(.link) { return .link }
        // **自前描画フレームワークの入力欄**(Compose / Flutter)。UIKit の UITextField/UITextView
        // ではないので上のクラス判定を素通りし、trait も button/staticText を持たないため、
        // これが無いと `.other` に落ちる —— 2026-08-06 に E2E-CMP で実害を観測した
        // (in-app だけ `other`・xcuitest は `textView`。型セレクタが探索と実行で食い違う)。
        //
        // 判定は**テキスト入力 trait(1<<18)**。実測値(iPhone 17 Pro / iOS 27.0):
        //   Compose `AccessibilityElement`      traits=1<<47|1<<18  UITextInput 非準拠
        //   Flutter `TextInputSemanticsObject`  traits=1<<37|1<<18  UITextInput 準拠
        // 上位ビットはフレームワーク固有なので見ない。**分岐は UITextInput 準拠**で、
        // これが XCUITest の elementType と一致する(同じ画面で実測):
        //   Flutter → textField / Compose → textView(パスワード欄も同じ = secure は出ない)。
        // ここを片方に寄せると、寄せなかった側が xcuitest と食い違う
        if t.contains(Self.textEntryTrait) {
            return node.conforms(to: UITextInput.self) ? .textField : .textView
        }
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
        case .toggle: return "Switch"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .image: return "Image"
        case .adjustable: return "Slider"
        case .cell: return "Clickable"
        case .link: return "Link"
        case .searchField: return "SearchField"
        case .picker: return "Picker"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .alert: return "Alert"
        case .keyboardKey: return "KeyboardKey"
        case .webView: return "WebView"
        case .other: return "Other"
        }
    }
}
