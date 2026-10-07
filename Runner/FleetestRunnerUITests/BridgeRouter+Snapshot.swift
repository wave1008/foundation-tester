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
                         insideWebView: Bool = false,
                         overlayWindowIndices: Set<Int> = []) {
        var gathered: [Gathered] = []
        if overlayWindowIndices.isEmpty {
            gather(node, depth: depth, screen: screen, insideWebView: insideWebView,
                   gathered: &gathered,
                   keyboardFrame: &keyboardFrame, offscreenHints: &offscreenHints)
        } else {
            // 根(アプリ)を自分で出してから窓ごとに辿る(手前の窓の中身に inOverlayWindow を付ける。
            // BridgeRouter.overlayWindows の doc)。順序・深さは gather(node) 1回と同じ
            if shouldInclude(node, screen: screen) {
                gathered.append(Gathered(info: makeInfo(node, ref: 0, depth: depth), frame: node.frame))
            }
            var contributing = Set<Int>()
            for (index, window) in node.children.enumerated() {
                let start = gathered.count
                gather(window, depth: depth + 1, screen: screen, insideWebView: insideWebView,
                       gathered: &gathered,
                       keyboardFrame: &keyboardFrame, offscreenHints: &offscreenHints)
                if overlayWindowIndices.contains(index) {
                    for i in start..<gathered.count { gathered[i].info.inOverlayWindow = true }
                    if gathered.count > start { contributing.insert(index) }
                }
            }
            lastContributingOverlayWindows = contributing
        }
        // **画面全体の枠の Toolbar(浮いたバーの入れ物)を出さない**: iOS 26 以降の `_UIFloatingBarContainerView` は型 toolbar・
        // 枠が画面全体(実測 0,0 402x874)で、中のボタンとは別に手前に載る。ホストの覆いの判定が「すべての要素が #Toolbar に
        // 覆われている」と読んで撃つ前の送りが空振りし、タップも吸われた(E2EX-RN の sticky・date、SwiftUI の pinch)。
        // 帯の形の本物のツールバーは画面全体の枠にならない。型名はここでは小文字(typeName の後で正規化済み)
        gathered.removeAll { item in
            ElementInfo.normalizedType(item.info.type) == "toolbar" && !screen.isEmpty
                && abs(item.frame.width - screen.width) <= 1 && abs(item.frame.height - screen.height) <= 1
        }

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
                        rescale inherited: AXFrameRescale? = nil,
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
        // **容器(子を持つセマンティクスのノード)は縮まずに FlutterView の実の枠を申告し続ける**ので写さない
        // (写すと画面の3倍になる。実測: 縮むのは各容器の先頭の子 = 容器自身のノードと葉だけ)。見つけた補正は子孫へ渡す
        let rescale = Self.flutterRescale(node, screen: screen, inherited: inherited)
        let frame = inherited.flatMap { Self.reportsTheWholeView(node.frame, screen: screen) ? nil : $0 }
            .map { Self.cgRect($0.apply(Self.ftRect(node.frame))) } ?? node.frame
        if isWebView && insideWebView {
            for child in node.children {
                gather(child, depth: depth, screen: screen, insideWebView: true, rescale: rescale,
                       gathered: &gathered,
                       keyboardFrame: &keyboardFrame,
                       offscreenHints: &offscreenHints)
            }
            return
        }
        if shouldInclude(node, frame: frame, screen: screen) {
            let info = makeInfo(node, frame: frame, ref: 0, depth: depth)
            gathered.append(Gathered(info: info, frame: frame))
        } else if insideWebView, offscreenHints.count < BridgeAPI.maxSnapshotElements,
                  isOffscreenHintCandidate(node, screen: screen) {
            // ref 0(座標表に入れない・タップ対象にしない)。Captured.offscreen 参照。
            // **この別枠上限は間引きと無関係**(hint は elements に混ざらない)
            offscreenHints.append(makeInfo(node, ref: 0, depth: depth))
        }
        for child in node.children {
            gather(child, depth: depth + 1, screen: screen,
                   insideWebView: insideWebView || isWebView, rescale: rescale,
                   gathered: &gathered, keyboardFrame: &keyboardFrame,
                   offscreenHints: &offscreenHints)
        }
    }

    private func shouldInclude(_ node: XCUIElementSnapshot, frame: CGRect? = nil, screen: CGRect) -> Bool {
        let frame = frame ?? node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard screen.isEmpty || frame.intersects(screen) else { return false }
        return isEligible(node, frame: frame, screen: screen)
    }

    /// **Flutter のオーバーレイ後に 1/画面倍率へ縮んだ木を実の枠へ写す**(in-app の `InAppSnapshot.rescaleBelow` と
    /// 同じ事象・判定は `AXFrameRescale` を共有)。始めるのは「子を持つ other のノードが
    /// ちょうど『画面 ÷ 倍率』を申告した」とき。引き継ぐのは Flutter のノードとその scroll 容器(`UIScrollView`)
    /// だけで、他の UIKit の view(PlatformView の中身 = 実の view ジオメトリを持つ)で外す。
    /// FlutterView が画面全体でない構成(add-to-app)は見つからない = 申告どおり(推測で写さない)
    private static func flutterRescale(_ node: XCUIElementSnapshot, screen: CGRect,
                                       inherited: AXFrameRescale?) -> AXFrameRescale? {
        let axClass = axClassName(node)
        if let inherited {
            return axClass == nil || axClass == "UIAccessibilityElement" || axClass == "UIScrollView"
                ? inherited : nil
        }
        // **縮んだ枠を申告するのは容器の先頭の子(容器自身のノード = 子の無い other)**で、写すのは容器の下全体
        // (in-app の SemanticsObjectContainer と同じ形。実測: 0,0 134x291.3 の葉の後に兄弟として要素が並ぶ)。
        // 倍率は iPhone の 3・2 を順に当てる(どちらかにちょうど一致したときだけ写す)
        guard !screen.isEmpty, let own = node.children.first,
              own.elementType == .other, own.children.isEmpty else { return nil }
        return flutterScreenScales.lazy.compactMap {
            AXFrameRescale.shrunkSubtree(reported: ftRect(own.frame), view: ftRect(screen), screenScale: $0)
        }.first
    }

    private static let flutterScreenScales: [Double] = [3, 2]

    /// 画面(= FlutterView)と同じ枠か(誤差 1pt = AXFrameRescale.tolerance と同じ丸め)
    private static func reportsTheWholeView(_ frame: CGRect, screen: CGRect) -> Bool {
        abs(frame.minX - screen.minX) <= 1 && abs(frame.minY - screen.minY) <= 1
            && abs(frame.width - screen.width) <= 1 && abs(frame.height - screen.height) <= 1
    }

    private static func ftRect(_ r: CGRect) -> FTRect {
        FTRect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
    }

    private static func cgRect(_ r: FTRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    /// 画面外ヒント(offscreenHints)の候補判定。サイズガードは shouldInclude と共有、
    /// 画面交差ガードだけ反転する(「画面と交わらない」ときだけヒント化する。screen が空だと
    /// 交差判定ができないので対象にしない)
    private func isOffscreenHintCandidate(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard !screen.isEmpty, !frame.intersects(screen) else { return false }
        return isEligible(node, frame: frame, screen: screen)
    }

    /// 型・テキストによる採用資格(画面内/外は問わない)。shouldInclude(可視要素)と
    /// isOffscreenHintCandidate(WebView 配下の画面外ノード)が共有する
    private func isEligible(_ node: XCUIElementSnapshot, frame: CGRect, screen: CGRect) -> Bool {
        // 画面の大半を覆う Other コンテナは identifier があっても除外する。
        // タップ対象になり得ず、id が「タブ」等に見えると FM の誤タップを誘発する
        // (SwiftUI の .accessibilityIdentifier がコンテナに付くケース)。
        if node.elementType == .other {
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
        // その他(Other/Group 等)は identifier 付きのみ。ラベルだけのライブリージョンは文字として出す
        default:
            return !node.identifier.isEmpty || Self.isLiveRegionText(node)
        }
    }

    /// `LiveRegionText`(BridgeDTO)の判定を XCUITest の snapshot に当てる。特性は **XCTest の非公開属性**
    /// (`traits`)なので、取れなければ false = 今までどおり落とす
    private static func isLiveRegionText(_ node: XCUIElementSnapshot) -> Bool {
        guard node.elementType == .other, !node.label.isEmpty else { return false }
        var traits: UInt64?
        _ = FTCatchObjCException({
            traits = ((node as AnyObject).value(forKey: "traits") as? NSNumber)?.uint64Value
        })
        guard let traits else { return false }
        return LiveRegionText.isLabelOnlyLiveRegion(traits: traits, label: node.label)
    }

    /// スクロールできる容器とみなす型(`ElementInfo.scrollable`)
    private static let scrollableTypes: Set<XCUIElement.ElementType> = [
        .scrollView, .table, .collectionView,
    ]

    private func makeInfo(_ node: XCUIElementSnapshot, frame: CGRect? = nil, ref: Int, depth: Int) -> ElementInfo {
        let frame = frame ?? node.frame
        return ElementInfo(
            ref: ref,
            type: Self.isLiveRegionText(node) ? Self.typeName(.staticText) : Self.typeName(node.elementType),
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
