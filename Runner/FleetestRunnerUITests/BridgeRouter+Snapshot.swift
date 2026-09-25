// BridgeRouter+Snapshot.swift
// XCUITest の木の走査・間引き・ElementInfo への変換(BridgeRouter のスナップショット収集)。

import Foundation
import UIKit
import XCTest

extension BridgeRouter {

    // MARK: - スナップショット収集・フィルタ

    /// 1パス目(gather)で拾った要素。ref はまだ未採番(0)
    private struct Gathered {
        var info: ElementInfo
        var frame: CGRect
    }

    /// **2パス化**: 1パス目(gather)は上限で打ち切らずに全件 preorder で集め、2パス目で
    /// dedupe → 間引き(超過時のみ)→ ref 採番を行う。
    /// **順序が要る**: SnapshotDedupe.isRedundant は「既に出したもの」基準なので、間引きより
    /// 先に全件へ通す(先に間引くと、落とした要素を基準にしていた冗長判定が変わる)。
    func collect(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                         elements: inout [ElementInfo], frames: inout [Int: CGRect],
                         identities: inout [Int: (identifier: String?, label: String?, type: String)],
                         truncated: inout Int,
                         truncatedTiers: inout [String: Int],
                         bulkExempt: inout Int,
                         keyboardFrame: inout CGRect?,
                         offscreenHints: inout [ElementInfo],
                         insideWebView: Bool = false) {
        var gathered: [Gathered] = []
        gather(node, depth: depth, screen: screen, insideWebView: insideWebView,
               gathered: &gathered,
               keyboardFrame: &keyboardFrame, offscreenHints: &offscreenHints)

        // isRedundant は [ElementInfo] を取るので**同じ列を2本持つ**。`deduped.map(\.info)` を
        // 毎回作ると、全件走査になった分そのまま要素ごとの配列確保になる(木が大きいほど効く)
        var deduped: [Gathered] = []
        var dedupedInfos: [ElementInfo] = []
        deduped.reserveCapacity(gathered.count)
        dedupedInfos.reserveCapacity(gathered.count)
        for item in gathered where !SnapshotDedupe.isRedundant(item.info, alreadyEmitted: dedupedInfos) {
            deduped.append(item)
            dedupedInfos.append(item.info)
        }

        let keptIndices: [Int]
        if deduped.count <= snapshotElementLimit {
            keptIndices = Array(deduped.indices)
        } else {
            let candidates = deduped.map { BridgeSnapshotThinning.Candidate(info: $0.info) }
            keptIndices = BridgeSnapshotThinning.indicesToKeep(candidates, max: snapshotElementLimit)
            // **落とした本人しか内訳を知らない**(ホストへ届くのは残った側だけ)
            for (key, count) in BridgeSnapshotThinning.droppedByTier(candidates, kept: keptIndices) {
                truncatedTiers[key, default: 0] += count
            }
            // 上限の外で送った bulk の件数(61)
            bulkExempt += BridgeSnapshotThinning.bulkExemptCount(candidates)
        }
        truncated += deduped.count - keptIndices.count

        for index in keptIndices {
            let ref = elements.count + 1
            var info = deduped[index].info
            info.ref = ref
            frames[ref] = deduped[index].frame
            identities[ref] = (info.identifier, info.label, info.type)
            elements.append(info)
        }
    }

    /// preorder 走査。不可視ノードはサブツリーごと除外。**上限で打ち切らない**(collect の2パス目が
    /// dedupe・間引きをまとめて行う)
    private func gather(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                        insideWebView: Bool,
                        gathered: inout [Gathered],
                        keyboardFrame: inout CGRect?,
                        offscreenHints: inout [ElementInfo]) {
        // キーボードはキー1つ1つが Button として大量に写り込むため、サブツリーごと除外
        // (4Kトークン対策。入力は /type がキーイベント合成で行うので情報として不要)。
        // 除外前に frame だけ記録する(SnapshotResponse.keyboardShown/keyboardFrame。
        // keyboardShown は keyboardFrame != nil から導く)
        if node.elementType == .keyboard {
            keyboardFrame = node.frame
        }
        if node.elementType == .keyboard || node.elementType == .key { return }
        // WebView は入れ子で複数出る(Compose iOS の interop ラッパで実測3重)。外側だけ残さないと
        // `.webView[1]` がどれを指すか読めない。Android ブリッジの nestedWebView と同じ規則
        let isWebView = node.elementType == .webView
        if isWebView && insideWebView {
            for child in node.children {
                gather(child, depth: depth, screen: screen, insideWebView: true,
                       gathered: &gathered,
                       keyboardFrame: &keyboardFrame,
                       offscreenHints: &offscreenHints)
            }
            return
        }
        if shouldInclude(node, screen: screen) {
            let info = makeInfo(node, ref: 0, depth: depth)
            gathered.append(Gathered(info: info, frame: node.frame))
        } else if insideWebView, offscreenHints.count < BridgeAPI.maxSnapshotElements,
                  isOffscreenHintCandidate(node, screen: screen) {
            // ref 0(座標表に入れない・タップ対象にしない)。Captured.offscreen 参照。
            // **この別枠上限は間引きと無関係**(hint は elements に混ざらない)
            offscreenHints.append(makeInfo(node, ref: 0, depth: depth))
        }
        for child in node.children {
            gather(child, depth: depth + 1, screen: screen,
                   insideWebView: insideWebView || isWebView,
                   gathered: &gathered, keyboardFrame: &keyboardFrame,
                   offscreenHints: &offscreenHints)
        }
    }

    private func shouldInclude(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard screen.isEmpty || frame.intersects(screen) else { return false }
        return isEligible(node, screen: screen)
    }

    /// 画面外ヒント(offscreenHints)の候補判定。サイズガードは shouldInclude と共有、
    /// 画面交差ガードだけ反転する(「画面と交わらない」ときだけヒント化する。screen が空だと
    /// 交差判定ができないので対象にしない)
    private func isOffscreenHintCandidate(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard !screen.isEmpty, !frame.intersects(screen) else { return false }
        return isEligible(node, screen: screen)
    }

    /// 型・テキストによる採用資格(画面内/外は問わない)。shouldInclude(可視要素)と
    /// isOffscreenHintCandidate(WebView 配下の画面外ノード)が共有する
    private func isEligible(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        // 画面の大半を覆う Other コンテナは identifier があっても除外する。
        // タップ対象になり得ず、id が「タブ」等に見えると FM の誤タップを誘発する
        // (SwiftUI の .accessibilityIdentifier がコンテナに付くケース)。
        if node.elementType == .other {
            let frame = node.frame
            let screenArea = screen.width * screen.height
            if screenArea > 0, (frame.width * frame.height) / screenArea > 0.85 {
                return false
            }
        }

        let hasText = !node.identifier.isEmpty || !node.label.isEmpty || valueString(node) != nil

        switch node.elementType {
        // 操作可能な要素はテキストがなくても含める(アイコンだけのボタン等)。
        // .icon は springboard のホーム画面アイコン(tapAppIcon 用。label のみで identifier を持たない)
        case .button, .textField, .secureTextField, .textView, .`switch`, .toggle,
             .slider, .cell, .link, .searchField, .segmentedControl, .pickerWheel,
             .stepper, .datePicker, .checkBox, .menuItem, .icon:
            return true
        // 表示要素はテキストを持つ場合のみ
        case .staticText, .image:
            return hasText
        // 画面構造の手がかり。webView は `.webView >> ...` のスコープ起点になるため
        // identifier が無くても残す(Web コンテンツは id を一切持たない = 唯一の絞り込み手段)
        case .navigationBar, .tabBar, .alert, .sheet, .webView:
            return true
        // スクロール容器は identifier が無くても残す(2026-08-08。in-app 側
        // InAppSnapshot.shouldInclude と同じ規律)。落とすと scrollFrame の候補も scroll マークも
        // 出ないまま木から消える(自前描画の容器は Other 型で id を持たないのが普通)
        case .scrollView, .table, .collectionView:
            return true
        // その他(Other/Group 等)は identifier 付きのみ
        default:
            return !node.identifier.isEmpty
        }
    }

    /// スクロールできる容器とみなす型(`ElementInfo.scrollable`)
    private static let scrollableTypes: Set<XCUIElement.ElementType> = [
        .scrollView, .table, .collectionView,
    ]

    private func makeInfo(_ node: XCUIElementSnapshot, ref: Int, depth: Int) -> ElementInfo {
        let frame = node.frame
        return ElementInfo(
            ref: ref,
            type: Self.typeName(node.elementType),
            identifier: node.identifier.isEmpty ? nil : node.identifier,
            label: node.label.isEmpty ? nil : node.label,
            value: valueString(node),
            placeholder: node.placeholderValue,
            enabled: node.isEnabled,
            frame: FTRect(x: frame.origin.x, y: frame.origin.y,
                          width: frame.width, height: frame.height),
            depth: depth,
            // isSelected = Compose iOS の On・Flutter iOS の Radio の選択中。false は送らない。
            // SwiftUI Toggle / Flutter の Checkbox・Switch は trait を立てず value "1"/"0" で出す
            // (オフの確定も含め CheckStateReading が読む)
            checked: node.isSelected ? true : nil,
            // スクロールできる容器か(scrollFrame の空振り検出用)。XCUITest は Android の
            // isScrollable に当たる属性を持たないので**型で判定する**(Shirates の iOS 側と同じ規則)。
            // 自前描画(Compose/Flutter)の容器は Other として出るため申告できない = false は送らない
            scrollable: Self.scrollableTypes.contains(node.elementType) ? true : nil,
            axClass: Self.axClassName(node))
    }

    /// 要素のクラス名(ElementInfo.axClass の doc)。**XCTest の非公開辞書**なので、無ければ nil で済ませる
    /// (Xcode の版で番号や辞書自体が変わっても、落ちずに「不明」へ縮退する)。
    /// 根の snapshot の各ノードに最初から入っており、ここでは辞書を1回引くだけ
    private static let axClassAttribute = NSNumber(value: 5004)
    private static func axClassName(_ node: XCUIElementSnapshot) -> String? {
        var name: String?
        _ = FTCatchObjCException({
            guard let attributes = (node as AnyObject).value(forKey: "additionalAttributes") as? [AnyHashable: Any],
                  let value = attributes[axClassAttribute] else { return }
            let text = String(describing: value)
            if !text.isEmpty { name = text }
        })
        return name
    }

    private func valueString(_ node: XCUIElementSnapshot) -> String? {
        guard let value = node.value else { return nil }
        let string = (value as? String) ?? String(describing: value)
        guard !string.isEmpty else { return nil }
        // **placeholder がそのまま value で来る欄は「空」**。WebKit は空の `<input>` の
        // AXValue に placeholder を入れて返すので(UIKit の入力欄は入れない)、正規化しないと
        // iOS の WebView だけ `value="WebView 入力"` になり `valueIs("")` が通らない。
        // Android のブリッジは同じ欄を empty で返す = ここが揃っていなかった
        // (2026-08-06 に E2E-iOS / E2E-CMP の WebView 画面で実測)。
        // 判定は clearInput の `remainingText` と同じ規則(同じ知見の2つ目の定義を作らない)
        if let placeholder = node.placeholderValue, string == placeholder { return nil }
        return string
    }

    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .`switch`: return "Switch"
        case .toggle: return "Toggle"
        case .slider: return "Slider"
        // UITableView/UICollectionView のセル。Android の「役割不明の clickable 容器」と
        // 同じバケツに入れるため名前を揃える(型語彙の唯一の正は E2EAppCMP/docs/ui-contract.md)
        case .cell: return "Clickable"
        case .link: return "Link"
        case .image: return "Image"
        case .icon: return "Icon"
        case .searchField: return "SearchField"
        case .segmentedControl: return "SegmentedControl"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .stepper: return "Stepper"
        case .datePicker: return "DatePicker"
        case .checkBox: return "CheckBox"
        case .menuItem: return "MenuItem"
        case .pageIndicator: return "PageIndicator"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .scrollView: return "ScrollView"
        case .webView: return "WebView"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .window: return "Window"
        case .other: return "Other"
        default: return "Type\(type.rawValue)"
        }
    }
}
