// 内蔵画面を2枚以上持つ Simulator(折りたたみの iPhone Duo)で、アプリが**主画面でない画面**に出ているときの
// 送り先と座標。**XCUICoordinate のタッチも `XCUIScreen.main` のスクショも主画面(Duo = 外側)にしか届かない**
// (実測・Xcode 27.2 beta 3: 開いた状態で座標の tap・ref の tap がどれも内側の画面に効かず、
// スクショは外側の絵だった)。届かせるには合成イベントを displayID 付きで送る
// (`XCSynthesizedEventRecord initWithName:displayID:interfaceOrientation:`。非公開 = CoordinatePinch と同じ規律:
// 実行時に確かめてから使い、無ければ 422)。
//
// 座標: 内側の画面は**縦長が本来の向き**(669x951pt)で、横に回して表示される。アプリの根(`app.frame`)は本来の向きの
// 大きさで、窓と木の枠は表示の向き(横長 951x669)で来る。合成イベントは本来の向きの座標で受けるので
// 表示の向きの (x, y) を (y, 表示の横幅 - x) へ回す(実測: 表示の向きの (433, 604) =「コントロール」タブの中心を
// (604, 518)・interfaceOrientation 1 で送ると当たった。回さない・向きに 3/4 を渡す形はどれも外れた)。
//
// **ホーム画面(SpringBoard)は根が主画面の大きさで来る**ので根では判定できない。両方の画面の窓を持ち、窓ごとに
// displayID が付く(実測: 内側の窓 669x951・外側の窓 466x678)。内側の窓の要素の枠は**本来の向き**(縦長)で来る
// (アプリの木は表示の向き = 横長。同じ画面でも座標系が違う)。だから「根が主画面以外の画面に合わないのに、
// 主画面以外の画面にホーム画面が出ている」(その画面の窓にアイコンがある)= SpringBoard と読み、木はその画面の窓だけを
// 採って枠を表示の向きへ回す(`treeInNative`)。閉じている間は内側の窓にアイコンが無い(実測: Dock とステータスバーだけ)。
//
// **画面が2枚以上の端末では、ランナーは自分の判断で撮らない**。`XCUIScreen.main` は主画面(Duo = 外側)を撮るので、
// 開いている間は内側が写らない。ランナーの中からはどちらが表示中か確かに言えない(XCUIScreen にも UIScreen にも表示中を
// 言う口は無い = 実行時にメソッドの一覧を確かめた。ホーム画面のアイコンでの判定は開閉の途中で外れる)。だから /screenshot は
// **ホストが devicectl で確かめた表示中の画面の displayID**(`display=`)を要求する。大きさは撮らずに `bounds`(px)/
// `scale` から採る。(開閉そのものが PosterBoard・SpringBoard 等を `FBSDisplayMode` の検査で落とすことがある =
// docs/open-issues.md。撮る・撮らないとは無関係に起きる)
//
// **主画面以外の画面が無い Simulator・実機では何もしない**(起動時に1回数えるだけ。判定の読みを足さない)。

import UIKit
import XCTest

enum DisplayRouting {
    /// アプリが出ている主画面以外の画面
    struct Target: Equatable {
        let displayID: UInt
        /// 表示の向きでの画面の大きさ(pt)= 木の座標系
        let interfaceSize: CGSize
        /// 表示の向きが本来の向きから回っている(木は横長・本来は縦長)
        let rotated: Bool
        /// 木の枠が本来の向きで来る(SpringBoard)。true なら木はこの画面の窓だけを採り、枠を `interfaceRect` で回す
        let treeInNative: Bool

        /// 表示の向きの点 → 合成イベントが受ける本来の向きの点
        func nativePoint(_ point: CGPoint) -> CGPoint {
            rotated ? CGPoint(x: point.y, y: interfaceSize.width - point.x) : point
        }

        /// 本来の向きの枠 → 表示の向きの枠(`nativePoint` の逆)
        func interfaceRect(_ native: CGRect) -> CGRect {
            guard rotated else { return native }
            return CGRect(x: interfaceSize.width - native.maxY, y: native.minX,
                          width: native.height, height: native.width)
        }

        /// 本来の向きでの画面(木を採るときの可視判定に使う)
        var nativeBounds: CGRect {
            CGRect(origin: .zero, size: rotated ? CGSize(width: interfaceSize.height, height: interfaceSize.width)
                                                : interfaceSize)
        }
    }

    struct Screen {
        let displayID: UInt
        /// 長辺・短辺(pt)。本来の向きの `bounds`(px)を `scale` で割った値(Duo の内側 = 669x951)
        let long: CGFloat
        let short: CGFloat
        let screen: XCUIScreen
    }

    /// 主画面以外の内蔵画面。プロセスで最初の1回(画面の構成はランナーの寿命の間変わらない)。
    /// 画面が1枚なら空 = 以後の判定はすべて素通り。**ここで撮らない**(ファイル冒頭)
    static let secondaryScreens: [Screen] = {
        guard let all = (XCUIScreen.self as AnyObject).value(forKey: "screens") as? [XCUIScreen], all.count > 1,
              let mainID = number(of: XCUIScreen.main, "displayID").map({ UInt($0) }) else { return [] }
        return all.compactMap { screen in
            guard let id = number(of: screen, "displayID").map({ UInt($0) }), id != mainID,
                  let bounds = rect(of: screen, "bounds"), let scale = number(of: screen, "scale"), scale > 0
            else { return nil }
            let width = bounds.width / CGFloat(scale), height = bounds.height / CGFloat(scale)
            guard width > 0, height > 0 else { return nil }
            return Screen(displayID: id, long: max(width, height), short: min(width, height), screen: screen)
        }
    }()

    /// 非公開の KVC。**例外はランナーごと落とす**(開いたまま落ちると SpringBoard も道連れになる)ので捕まえる
    private static func number(of object: NSObject, _ key: String) -> Double? {
        var value: Double?
        if FTCatchObjCException({ value = (object.value(forKey: key) as? NSNumber)?.doubleValue }) != nil { return nil }
        return value
    }

    private static func rect(of object: NSObject, _ key: String) -> CGRect? {
        var value: CGRect?
        if FTCatchObjCException({ value = (object.value(forKey: key) as? NSValue)?.cgRectValue }) != nil { return nil }
        return value
    }

    /// アプリの根の大きさ(本来の向き)と窓の大きさ(表示の向き)から決める(純粋関数)。
    /// 根の辺が主画面以外の画面の辺と一致したときだけ、その画面に出ていると読む
    static func target(rootSize: CGSize, windowSize: CGSize?, screens: [Screen]) -> Target? {
        let long = max(rootSize.width, rootSize.height), short = min(rootSize.width, rootSize.height)
        // frame は 1/scale pt 刻みの端数を持つ(スクショは 950.67x668.67・根は 669x951)ので 1pt 見逃す
        guard let screen = screens.first(where: { abs($0.long - long) <= 1 && abs($0.short - short) <= 1 })
        else { return nil }
        let rootLandscape = rootSize.width > rootSize.height
        let interfaceLandscape = windowSize.map { $0.width > $0.height } ?? rootLandscape
        let rotated = rootLandscape != interfaceLandscape
        let interface = rotated ? CGSize(width: rootSize.height, height: rootSize.width) : rootSize
        return Target(displayID: screen.displayID, interfaceSize: interface, rotated: rotated, treeInNative: false)
    }

    /// ホストが devicectl で確かめて /screenshot に渡した表示中の画面(`display=`)。ホーム画面がどちらに出ているかの
    /// 第一の根拠(ライブ操作は観測のたびに木より先に撮るので、操作1つ分より古くならない)。ランナーの /hinge が
    /// 開閉したら捨てる(`forgetReportedDisplay`)= 次の報告までアイコンでの判定に戻る。
    /// ハンドラは main で1本ずつ走る(BridgeHTTPServer)ので排他は要らない
    private static var reportedDisplay: UInt?

    static func noteReportedDisplay(_ id: UInt) { reportedDisplay = id }
    static func forgetReportedDisplay() { reportedDisplay = nil }

    /// SpringBoard(ホーム画面)がどの画面に出ているか。①ホストの報告(`reportedDisplay`)②無ければ、主画面以外の画面の
    /// 窓にアイコンがあるか(アプリが前面でも内側の窓にアイコンは残る = 実測。**開閉の後はアイコンが残ったまま外れる**
    /// ことがある = 実測。だから報告を先に見る)。**撮らずに決める**ので、表示の向きは実測の形(本来は縦長・表示は
    /// 横長 = Duo の内側。アプリの窓も同じ向きで来る)と置く
    static func homeScreenTarget(root: XCUIElementSnapshot) -> Target? {
        let chosen: Screen?
        if let reported = reportedDisplay {
            chosen = secondaryScreens.first { $0.displayID == reported }
        } else {
            chosen = secondaryScreens.first { screen in
                root.children.contains { displayID(ofSnapshot: $0) == screen.displayID && containsIcon($0, depth: 0) }
            }
        }
        return chosen.map {
            Target(displayID: $0.displayID, interfaceSize: CGSize(width: $0.long, height: $0.short),
                   rotated: true, treeInNative: true)
        }
    }

    /// 深さの上限は木の暴走よけ(ホーム画面のアイコンは窓から 7 段 = 実測)
    private static func containsIcon(_ node: XCUIElementSnapshot, depth: Int) -> Bool {
        if node.elementType == .icon { return true }
        guard depth < 12 else { return false }
        return node.children.contains { containsIcon($0, depth: depth + 1) }
    }

    /// SpringBoard か(非公開の `bundleID`。読めなければ false = ホーム画面の判定をしない側)
    static func isSpringBoard(_ app: XCUIApplication) -> Bool {
        var bundleID: String?
        if FTCatchObjCException({ bundleID = (app as NSObject).value(forKey: "bundleID") as? String }) != nil {
            return false
        }
        return bundleID == "com.apple.springboard"
    }

    /// 木のノード(窓)が載っている画面。読めなければ nil(非公開の `displayID`。例外はランナーごと落とすので捕まえる)
    static func displayID(ofSnapshot node: XCUIElementSnapshot) -> UInt? {
        let object = node as AnyObject
        guard object.responds(to: Selector(("displayID"))) else { return nil }
        var value: UInt?
        if FTCatchObjCException({ value = (object as? NSObject)?.value(forKey: "displayID") as? UInt }) != nil {
            return nil
        }
        return value
    }

    /// 撃つ直前の判定(根と最初の窓の大きさを1回ずつ読む)。主画面以外の画面が無ければ読まずに nil
    static func target(for app: XCUIApplication) -> Target? {
        guard !secondaryScreens.isEmpty else { return nil }
        let window = app.windows.firstMatch
        if let found = target(rootSize: app.frame.size, windowSize: window.exists ? window.frame.size : nil,
                              screens: secondaryScreens) {
            return found
        }
        guard isSpringBoard(app), let root = try? app.snapshot() else { return nil }
        return homeScreenTarget(root: root)
    }

    /// 木を撮った後の判定(撮った根と窓から決める = 読みを足さない)
    static func target(root: XCUIElementSnapshot, app: XCUIApplication) -> Target? {
        guard !secondaryScreens.isEmpty else { return nil }
        let window = root.children.first(where: { $0.elementType == .window })
        if let found = target(rootSize: root.frame.size, windowSize: window?.frame.size, screens: secondaryScreens) {
            return found
        }
        return isSpringBoard(app) ? homeScreenTarget(root: root) : nil
    }

    /// 画面が2枚以上あるか(= /screenshot に display= が要る・ランナーは自分で撮らない)
    static var isMultiDisplay: Bool { !secondaryScreens.isEmpty }

    /// ホストが指定した画面(主画面を含む)。知らない displayID は nil
    static func screen(displayID: UInt) -> XCUIScreen? {
        if let secondary = secondaryScreens.first(where: { $0.displayID == displayID }) { return secondary.screen }
        return number(of: XCUIScreen.main, "displayID").map({ UInt($0) }) == displayID ? XCUIScreen.main : nil
    }

    /// 主画面の長辺・短辺(pt)。画面が1枚なら従来どおり撮って測る。2枚以上なら撮らずに bounds / scale から
    /// (主画面が表示されていないことがある = 開いた Duo)
    static func mainScreenSides() -> (long: CGFloat, short: CGFloat)? {
        if secondaryScreens.isEmpty {
            let size = XCUIScreen.main.screenshot().image.size
            guard size.width > 0, size.height > 0 else { return nil }
            return (max(size.width, size.height), min(size.width, size.height))
        }
        guard let bounds = rect(of: XCUIScreen.main, "bounds"), let scale = number(of: XCUIScreen.main, "scale"),
              scale > 0 else { return nil }
        let width = bounds.width / CGFloat(scale), height = bounds.height / CGFloat(scale)
        return (max(width, height), min(width, height))
    }
}


