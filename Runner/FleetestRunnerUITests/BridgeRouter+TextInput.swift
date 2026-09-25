// BridgeRouter+TextInput.swift
// 文字入力(/type)・消去(/clear)の読み返しつき実装(BridgeRouter のテキスト入力ハンドラ)。

import Foundation
import UIKit
import XCTest

extension BridgeRouter {

    /// **`typeText` が返ったことを完了の根拠にしない**(handleClear と同じ規律。2026-08-01)。
    /// 打鍵はキーボード(別プロセス)経由で**非同期に**アプリへ届くため、200 を返した時点では
    /// アプリの状態に入っていない。高負荷ではさらに取りこぼしも起きる。
    ///
    /// **実害**(フル E2E・2026-08-01): `type "#field_single" "persist99"` の直後の送信タップが
    /// **空の値で処理された**(失敗時の画面は `single=persist99` / `len=9` なのに `submitted=`)。
    /// タッチは直接アプリへ届くのに文字はキーボード経由で遅れるので、順序が入れ替わる。
    /// つまり「入っていない」ではなく「まだ入っていない」を 200 で隠していた。
    ///
    /// 対策は読み返し: 期待値(入力前の値 + 送る本文)になるまで待ち、
    ///   - 期待値の**前方一致で止まった**(= 打鍵の取りこぼし)→ 足りないぶんだけ追送
    ///   - 期待値を**含んで長い**(= 追送が二重に入った)→ 余分を delete で削る
    ///   - どちらでもない(自動修正・書式付け・マスク欄の `•••`)→ **検証を諦めて受理**
    ///     (嘘の成功は潰したいが、加工された入力を失敗にはしない)
    /// 上限は周回数ではなく deadline と進捗なし回数(handleClear と同じ設計)。
    ///
    /// **「値が変わらなくなる」まで待ってから追送する**のが肝。まだ届いていないだけの欄へ
    /// 追送すると同じ文字を2回入れる(Android の `InputInjector` で実害。
    /// docs/design.md §Android のテキスト注入の規律)。
    ///
    /// 検証できない経路(ref なし・テキスト欄でない対象・secure 欄・文中の改行)は従来どおり
    /// `app.typeText` を1回だけ送る——ただし**この分岐だけ**焦点の有無を確かめてから送る
    /// (`requireKeyboardFocus`。焦点が無いまま撃つとランナーごと落ちるので、
    /// ここでだけライブクエリを払って先に 422 で失敗させる)。
    ///
    /// **読み返しはスナップショットで行い、ライブクエリ(`descendants` + `hasKeyboardFocus`)は
    /// 検証つきの主経路(isTextInput な ref)には使わない**。ライブクエリは1回 0.5s 級で、
    /// happy path が倍以上遅くなる(実測: /type の p50 が 842ms → 2,166ms)。
    /// **打鍵も `app.typeText` のまま**にする —— 要素に対する
    /// `typeText` はイベント合成の失敗が XCTest の失敗になり**ランナーごと落ちる**
    /// (実測1件: 高負荷で `Type '...' into "field_single" TextView` の Synthesize event を
    /// 最後にランナーが死んだ)。
    func handleType(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TypeRequest.self, body)
        let app = try requireForegroundAppForInput()
        let focusBefore = focusBeforeTappingNonInput(app, ref: req.ref)
        var tapped: CGPoint?
        if let ref = req.ref {
            // tap() が quiescence まで待つため追加待ちは不要(旧: 固定400ms・keyboards クエリは
            // キーボードが別プロセス扱いのため常にタイムアウトし逆効果だった。2026-07-12実測)
            let point = try resolvePoint(ref: ref, x: nil, y: nil)
            coordinate(app, point).tap()
            tapped = point
        }
        // 末尾の改行1つは本文と分けて送る(改行は Return キー相当で、値には残らない=検証対象外)。
        // 本文を入れ切ってから発火するので「空のまま送信された」も同時に塞げる
        let (main, hasTrailingNewline) = Self.splitTrailingNewline(req.text)
        // 入力前の値は**直近スナップショットの値をそのまま使う**(ホストは /type の直前に必ず
        // snapshot を撮っている)。ここで撮り直すと happy path に取得1回ぶん乗る
        //
        // **secure 欄(`isMaskedInput`)もここへ落とす**: 中身は伏せ字(`•`)でしか読めないため、
        // 下の読み返しループに入れると `expected` に `•` が混ざり、それを本物の1文字として
        // resend して欄へ literal な bullet を打ち込む(実害。TypeReadback.isMaskedInput
        // の doc 参照)。検証を諦めて1回だけ送る側にとどめる
        if !main.contains("\n"),
           let target = req.ref.flatMap({ refElements[$0] }),
           TypeReadback.isTextInput(target), !TypeReadback.isMaskedInput(target) {
            let note = try performTypeReadback(app, target: target, main: main)
            // 本文を入れ切ってから発火する(app 全体へ送るのは従来どおり。要素への typeText は
            // ランナーごと落ちうる)
            if hasTrailingNewline { app.typeText("\n") }
            return .json(OKResponse(note: note))
        }
        // **この分岐だけ焦点の有無を確かめる**(ライブクエリ = 上のコメントで避けている
        // コストそのものだが、検証つきの主経路には持ち込まない・この分岐だけで払う)。
        // 焦点が無いまま `app.typeText` を撃つと XCTest が
        // "Neither element nor any descendant has keyboard focus" で失敗し、
        // テストが Tear Down して**ランナーごと落ちる**(ref が入力欄でない・
        // ref 無しで未フォーカスのどちらも踏む)。in-app は同じ状況で 409 を返せるので、
        // ここは 422 で先に失敗させて揃える(409 は requireApp() 専用という不変条件)
        let focusAfter = try Self.requireKeyboardFocus(app)
        try Self.requireFocusMoved(from: focusBefore, to: focusAfter, tapped: tapped, action: "type")
        // **末尾に改行があるときだけ、焦点中の要素を読み返しに乗せる**(v129)。改行が無ければ
        // 取りこぼしても後続の読みで収束するが、改行はこの直後に Return を撃って確定させるため、
        // 取りこぼした最後の1文字を Return がそのまま確定させる
        // (E2E-RN 実測: `tap("#field_single")` → `type("pqr\n")` が "pq" で確定。打鍵はキーボード
        // 経由で非同期に届くため、高負荷では届く前に Return が先着する)。
        // 対象は焦点(`focusAfter`)を直近の snapshot と identifier/frame で突き合わせて特定する
        // (`matchFocusedElement`)。ref 経路が使う `refElements` の表はこの経路(ref なし)には無いので
        // ここで一度だけ突き合わせる。曖昧・非入力欄・secure 欄・文中に改行が残る形は
        // 検証不能として従来どおり一発撃ちへ落ちる
        if hasTrailingNewline, !main.contains("\n"),
           let captured = try? captureOnce(app),
           let target = Self.matchFocusedElement(focusAfter, in: captured.elements),
           TypeReadback.isTextInput(target), !TypeReadback.isMaskedInput(target) {
            let note = try performTypeReadback(app, target: target, main: main)
            app.typeText("\n")
            return .json(OKResponse(note: note))
        }
        app.typeText(req.text)
        return .json(OKResponse())
    }

    /// `/type` の読み返しループ本体。ref 経路(`refElements` から引いた対象)・焦点経由
    /// (`matchFocusedElement` で特定した対象)の両方から呼ぶ共有実装。呼び手は `target` が
    /// `TypeReadback.isTextInput` かつ `!isMaskedInput` であることを確認してから呼ぶこと
    /// (secure 欄を読み返しに乗せると伏せ字を literal 文字として撃ち込む。TypeReadback.isMaskedInput の doc)。
    /// 戻り値は driverFallback へ運ぶ注記(打ち直しが起きたときだけ non-nil)。
    /// 末尾の改行は呼び手が本体の読み返し成立後に別送する(呼び手側のコメント参照)
    private func performTypeReadback(_ app: XCUIApplication, target: ElementInfo,
                                     main: String) throws -> String? {
        let expected = TypeReadback.normalizedValue(of: target) + main
        var pending = main
        var previous: String?
        var stagnantRounds = 0
        var rounds = 0
        var retypes = 0
        var retypeAbandoned = false
        let deadline = Date().addingTimeInterval(Self.typeBudgetSeconds)
        loop: while true {
            app.typeText(pending)
            rounds += 1
            // 読めない・曖昧 = 検証不能なので受理する(TypeReadback.value 参照)
            guard let actual = try awaitCommit(app, target: target,
                                               expected: expected, deadline: deadline) else { break }
            // 目標は撃つ前の値 + 本文が既定で、ヒントが value に載る欄では本文だけへ採り直す
            // (規則はホストと共有 = TypeReadback.readbackTarget。採り直さないと `.retype` が
            // ヒント文字列ごと打ち込む)
            let readbackTarget = TypeReadback.readbackTarget(expected: expected, typedOnly: main, actual: actual)
            switch TypeReadback.plan(expected: readbackTarget, actual: actual) {
            case .done, .unverifiable:
                break loop
            case .resend(let missing):
                pending = missing
            case .deleteExcess(let count):
                pending = String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)
            case .retype where retypes >= TypeReadback.maxRetypes:
                // 打ち直しても同じ形 = アプリ側の加工。v104 より前と同じく受理する(TypeReadback.maxRetypes)
                retypeAbandoned = true
                break loop
            case .retype:
                // 中央の欠落 = 消してから全文を打ち直す(.deleteExcess と同じ機構。TypeReadback.Plan.retype)
                pending = String(repeating: XCUIKeyboardKey.delete.rawValue, count: actual.count) + readbackTarget
                retypes += 1
            }
            stagnantRounds = (actual == previous) ? stagnantRounds + 1 : 0
            previous = actual
            if stagnantRounds >= Self.typeMaxStagnantRounds || Date() >= deadline {
                // 残った値そのものは出さない(パスワード欄も通る経路)。長さと周回数だけ出す。
                // **409 ではなく 422**(理由は handleClear のコメント)
                throw BridgeError(422, "the field did not end up holding the expected text"
                    + " (\(rounds) round(s) of keystrokes left \(actual.count) character(s)"
                    + " against the expected \(expected.count))")
            }
        }
        // 打ち直した事実は注記で返す(ホストは driverFallback へ載せる = 緑の run で何回起きたかを数える口)
        if retypeAbandoned {
            return "retyped the whole text once, but the field still lost the same characters;"
                + " accepted as input the app transforms"
        }
        if retypes > 0 {
            return "retyped the whole text \(retypes) time(s) after a keystroke was dropped mid-string"
        }
        return nil
    }

    /// 焦点(`requireKeyboardFocus` が撮ったライブの値)を直近の snapshot の要素と突き合わせる。
    /// ref 経路は `refElements` の表から対象を引けるが、この経路(ref なし)は焦点そのものしか
    /// 手掛かりが無いのでここで一度だけ突き合わせる。規律は `TypeReadback.value(of:in:)` と同じ:
    /// identifier があればそれで、無ければ frame で、**候補が複数(曖昧)なら nil**
    /// (別の要素を誤って読み返しの対象にすると、検証にも取りこぼしにもならない別要素へ delete/resend
    /// を打ち込む)
    private static func matchFocusedElement(_ focus: FocusMark, in elements: [ElementInfo]) -> ElementInfo? {
        let matches: [ElementInfo]
        if !focus.identifier.isEmpty {
            matches = elements.filter { $0.identifier == focus.identifier }
        } else {
            let frame = FTRect(x: focus.frame.origin.x, y: focus.frame.origin.y,
                               width: focus.frame.width, height: focus.frame.height)
            matches = elements.filter { $0.frame == frame }
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// 入力の打ち切り時間(秒)と、値が変わらない周回の許容数。handleClear と同じ設計・同じ値
    /// (どちらも「1周まるごと打鍵が落ちる」ことがあるので 1 では早すぎる)
    private static let typeBudgetSeconds: TimeInterval = 8
    private static let typeMaxStagnantRounds = 4
    /// 追送に踏み切る前に「値が動かないこと」を確認する時間。**実測の反映遅れより十分長く取る**
    /// (6シミュレータ並列 + Android スイート並走で、打鍵が値に載るまでの実測は 0.7s 以下)。
    /// 短くすると、まだ届いていないだけの欄へ追送して二重入力になる
    private static let typeStableSeconds: TimeInterval = 1.5
    /// 読み返しの間隔。1回ごとにツリー取得(数十〜数百 ms)が乗るので、これ以上細かくしない
    private static let typePollSeconds: TimeInterval = 0.05

    /// 期待値になるまで待ち、最後に読めた値を返す(nil = 検証不能。TypeReadback.value 参照)。
    /// 抜ける条件は3つ: **期待値に一致** / **値が typeStableSeconds のあいだ変わらない** / deadline。
    /// 「変わらなくなるまで待つ」のが肝 —— 打鍵はキーボード(別プロセス)経由で非同期に届くので、
    /// まだ届いていない欄へ追送すると二重入力になる。
    /// 一致していれば最初の1取得で返るので、happy path に待ちは乗らない
    private func awaitCommit(_ app: XCUIApplication, target: ElementInfo,
                             expected: String, deadline: Date) throws -> String? {
        var lastValue = TypeReadback.value(of: target, in: try captureOnce(app).elements)
        var lastChange = Date()
        while true {
            guard let value = lastValue else { return nil }
            if value == expected { return value }
            if Date() >= deadline { return value }
            if Date().timeIntervalSince(lastChange) >= Self.typeStableSeconds { return value }
            Thread.sleep(forTimeInterval: Self.typePollSeconds)
            let current = TypeReadback.value(of: target, in: try captureOnce(app).elements)
            if current != lastValue {
                lastChange = Date()
                lastValue = current
            }
        }
    }

    /// 末尾の改行1つだけを本文から切り離す(text 全体が "\n" のときは分離しない)。
    /// InAppBridge / AndroidDriver の同名ヘルパと同じ規則 —— 「type の末尾改行 = pressEnter」が
    /// 3ブリッジ共通の契約
    private static func splitTrailingNewline(_ text: String) -> (main: String, hasTrailingNewline: Bool) {
        guard text != "\n", text.hasSuffix("\n") else { return (text, false) }
        return (String(text.dropLast()), true)
    }

    /// **/type の未検証な分岐(guard の else)だけが払うライブクエリ**(handleType 冒頭の
    /// コメント参照。検証つきの主経路には持ち込まない)。焦点が無いまま `app.typeText` を
    /// 撃つと XCTest の event synthesis が失敗し、テストが Tear Down してランナーごと落ちる。
    /// in-app の同じ状況の文言(`no focused input field — tap the target field
    /// first`)と揃える。**409 ではなく 422**(409 は requireApp() 専用という不変条件。
    /// ここは「セッションはあるが今は打てない」であってセッション消失ではない)
    @discardableResult
    private static func requireKeyboardFocus(_ app: XCUIApplication) throws -> FocusMark {
        guard let focused = focusMark(app) else {
            throw BridgeError(422, "nothing has keyboard focus, so there is nothing to type into."
                + " If you passed a ref, it is probably not the input element itself — tapping a"
                + " container does not move focus. Tap the field (or pass the ref of the element"
                + " whose type is a text field) and try again")
        }
        return focused
    }

    /// **焦点を持つ入力欄**(型を入力欄に限る)。型を問わない `firstMatch` は、焦点のある欄を
    /// もう一度タップして開いた編集メニュー(Paste / AutoFill の collectionView)を返すことがあり、
    /// 値の読めないその要素を相手に空打ちして 200 を返していた(2026-09-17 M13。SwiftUI・24 回に 1 回)
    private static func focusedInput(_ app: XCUIApplication) -> XCUIElement {
        let types: [UInt] = [XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField]
            .map(\.rawValue)
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true AND elementType IN %@", types))
            .firstMatch
    }

    /// 焦点を持つ要素の控え。タップの前後で「焦点が動いたか」を比べるためだけに使う
    private struct FocusMark: Equatable {
        let identifier: String
        let type: XCUIElement.ElementType
        let frame: CGRect
    }

    /// ライブクエリ1回(0.5s 級)。検証つきの主経路には持ち込まない(handleType 冒頭のコメント参照)
    private static func focusMark(_ app: XCUIApplication) -> FocusMark? {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard let snap = try? focused.snapshot() else { return nil }
        return FocusMark(identifier: snap.identifier, type: snap.elementType, frame: snap.frame)
    }

    /// **入力欄でない ref への type / clear は、タップで焦点が動いたことを確かめる**。確かめないと、
    /// 焦点を持たない要素を叩いても前の欄の焦点はそのまま残り、**前の欄へ打って(消して)200 を返す**
    /// (ホストは xcuitest の読み返しを信じて二重に確かめないので誤った緑になる。実測: Flutter で
    /// パスワード欄に焦点を残して送信ボタンの ref へ type → パスワード欄に追記)。
    /// 比べるのは**タップ前に焦点を持っていた要素そのもの**で、タップした座標ではない —— 最初に
    /// キーボードが出たとき SwiftUI は中身をずらすので、叩いた時点の座標では正しい欄を取り違える。
    /// 入力欄の ref はここを通さない(叩けば焦点が動くので、主経路にライブクエリを足さない)
    private func focusBeforeTappingNonInput(_ app: XCUIApplication, ref: Int?) -> FocusMark? {
        guard let ref, let target = refElements[ref], !TypeReadback.isTextInput(target) else { return nil }
        return Self.focusMark(app)
    }

    private static func requireFocusMoved(from before: FocusMark?, to after: FocusMark,
                                          tapped: CGPoint?, action: String) throws {
        guard let before, let tapped, after == before, !after.frame.contains(tapped) else { return }
        throw BridgeError(422, "keyboard focus did not move when the target was tapped — it is still on"
            + " the field that had it before, so \(action) would act on that field instead."
            + " The ref is probably not a text input: pass the ref of the input element itself")
    }

    /// hasKeyboardFocus な要素を探して末尾へカーソルを送ってから delete を打つ。**文中をタップして
    /// delete すると左側の一部しか消えない**ため、必ず frame の右端近くをタップしてカーソルを
    /// 末尾に揃える。
    ///
    /// **周回数を固定しないこと**(2026-07-31 実測)。高負荷では `typeText` が打鍵を取りこぼし、
    /// 送った delete が全部は入らない —— 実測の失敗3件はいずれも
    /// `"hello123"(8打鍵)→"hel"`、`"hel"(3打鍵)→"h"` と、**毎周 6 割前後しか入らない**。
    /// 2周固定だった頃はここで打ち切られ「値が残っています」で落ちていた(高負荷で約 2%)。
    /// 残り文字数は単調に減るので、**空になるまで回せば収束する**。
    /// 上限は周回数ではなく deadline と「進捗なし」で持つ:
    /// 進捗なしを数えるのは、delete では消えない欄(入力を書き戻すバリデーション等)で
    /// deadline いっぱい叩き続けないため。通常は1周で終わるので速度は変わらない。
    ///
    /// **失敗は 409 ではなく 422**(2026-07-31 修正)。ここは「セッションはあるが今のこの画面では
    /// クリアできない」であって、`requireApp` のセッション消失とは別物。409 で返していた頃は
    /// `SessionRecoveryDriver` が**一律にセッション消失と断定**し、無用な activate を撃ったうえで
    /// 「ランナーが再起動した可能性」という誤った理由でステップを落としていた(実害: E2E の
    /// clearInput 失敗の原因が読めなかった)。**この経路で 409 を返さないこと** —
    /// XCUITest ランナーの 409 は `requireApp` の1箇所だけという不変条件を
    /// `BridgeRouterStatusContractTests` が守っている。
    /// 422 を選ぶ理由: 501/404 は「このエンジンでは不可」(XCUITest へのフォールバック判定)、
    /// 503 は「アプリが起動していない」に取られているため。
    /// ホスト側の `isClearInputFallback` は 409 と同じく 422 でもフォールバックを許すので、
    /// hybrid の in-app→XCUITest の再試行はこれまでどおり効く。
    ///
    /// **ref を渡された経路はタップ直後の1回読みで焦点を判定しない**(2026-09-17 実測)。
    /// Flutter はタップからフォーカス移動までが非同期で、直後は前の欄や無焦点が見える
    /// (`awaitClearFocusTarget` 参照。InAppBridge.requireFocusMoved と同じ設計)。
    func handleClear(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(ClearRequest.self, body)
        let app = try requireForegroundAppForInput()
        let focused: XCUIElement
        if let ref = req.ref {
            let point = try resolvePoint(ref: ref, x: nil, y: nil)
            let focusBefore = Self.focusMark(app)
            coordinate(app, point).tap()
            let refIsTextInput = refElements[ref].map(TypeReadback.isTextInput) ?? false
            focused = try Self.awaitClearFocusTarget(app, tapped: point, focusBefore: focusBefore,
                                                     refIsTextInput: refIsTextInput)
        } else {
            let typed = Self.focusedInput(app)
            let f = typed.exists ? typed : app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            // **原因を名指しする**(2026-08-12 のブラウザ監査): 「ref を指定してください」だけだと
            // ref を渡した呼び手が読む先を失う —— 実際に起きるのは「渡した ref が入力欄ではなく、
            // タップしても焦点が立たない容器だった」形(Safari の畳んだアドレスバー等)。
            // ref なしのこの経路は焦点がすでに立っている前提(タップしていない)なので待たない
            guard f.exists else {
                throw BridgeError(422, "nothing has keyboard focus, so there is no field to clear."
                    + " If you passed a ref, it is probably not the input element itself — tapping a"
                    + " container does not move focus. Tap the field (or pass the ref of the element"
                    + " whose type is a text field) and try again")
            }
            focused = f
        }
        if try Self.presentRemainingText(of: focused) == nil {
            // 空白のみの内容は a11y から読めない(value が nil か placeholder と同値に見える。
            // TypeReadback のコメント参照)ので、この欄が本当に空か「見えない空白が残っている」かは
            // 区別できない。長さも分からないので固定本数の当て推量で消す——空欄への delete は
            // no-op なので外れて多く撃っても損は無く、それでも残るほど長ければ次の /type の
            // 読み返し不一致が唯一の合図になる(2026-08-31・実機実測)
            try Self.requirePresent(focused)
            let frame = focused.frame
            coordinate(app, CGPoint(x: frame.maxX - 4, y: frame.midY)).tap()
            focused.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                     count: Self.invisibleContentDeleteBurst))
        }
        let deadline = Date().addingTimeInterval(Self.clearBudgetSeconds)
        var previous: String?
        var stagnantRounds = 0
        var rounds = 0
        while let text = try Self.presentRemainingText(of: focused), !text.isEmpty {
            // 「打っても減らない」が続いたら delete では消せない欄。deadline まで叩かず抜ける
            stagnantRounds = (text == previous) ? stagnantRounds + 1 : 0
            if stagnantRounds >= Self.clearMaxStagnantRounds || Date() >= deadline { break }
            previous = text
            rounds += 1
            try Self.requirePresent(focused)
            let frame = focused.frame
            coordinate(app, CGPoint(x: frame.maxX - 4, y: frame.midY)).tap()
            focused.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        }
        if let residual = try Self.presentRemainingText(of: focused) {
            // 残った値そのものは出さない(パスワード欄も通る経路)。長さと周回数だけ出す
            throw BridgeError(422, "could not empty the field"
                + " (\(residual.count) character(s) still there after \(rounds) round(s))")
        }
        // **ref の欄そのものを木で読み返す**(ホストの事後検証と同じ材料)。ライブの焦点要素の値だけで
        // 「空になった」と言うと、焦点が別の要素に化けていたときに消えていない欄へ 200 を返す(M13)。
        // 伏せ字の欄は読み返しの材料にしない(TypeReadback.isMaskedInput)
        if let ref = req.ref, let target = refElements[ref], !TypeReadback.isMaskedInput(target) {
            while true {
                let elements = try captureOnce(app).elements
                guard let left = TypeReadback.value(of: target, in: elements), !left.isEmpty else { break }
                guard Date() < deadline else {
                    throw BridgeError(422, "could not empty the field (\(left.count) character(s)"
                        + " still there after \(rounds) round(s); the focused element reported empty)")
                }
                rounds += 1
                // 位置は今の木から取る(キーボードで中身がずれる)。打鍵は**アプリ全体へ**送る ——
                // 編集メニューが開いている間は要素に向けた typeText が別の要素へ向き、欄に届かなかった
                // (40 回中 2 回)。キーボードの入力先は叩いた欄(最前のレスポンダ)なので app で届く
                let now = elements.first { current in
                    if let identifier = target.identifier, !identifier.isEmpty {
                        return current.identifier == identifier
                    }
                    return current.frame == target.frame
                }?.frame ?? target.frame
                coordinate(app, CGPoint(x: now.x + now.width - 4, y: now.y + now.height / 2)).tap()
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left.count))
            }
        }
        // **控えの値も空にする**: /type は「入力前の値」を直近スナップショットの控え(refElements)から
        // 取るので、clear → type を撮り直さずに続けると clear 前の値を期待に足して再送し、
        // 消したはずの文字列が戻る(実機 iPhone 13・2026-08-31: replace で `   モバイル   `)
        if let ref = req.ref { refElements[ref]?.value = nil }
        return .json(OKResponse())
    }

    /// ref を渡された clear の焦点待ち(FocusWait.waitSeconds が上限・FocusWait.pollSeconds が刻み。
    /// 唯一の定義元は BridgeDTO の doc)。**一致していれば最初の1取得で返る**ので happy path は
    /// 遅くならない。以後の消去/残り判定はここで返した要素に対して行う——差し替えないと、
    /// 前の欄が残焦点のまま「空になった」と誤読する(実測: シミュレータの xcuitest で
    /// `clearInput` が値の残存を見逃した。2026-09-17)
    /// **受け入れるのは「タップした点を含む」か「タップ前の焦点から変わった」焦点**。後者を外すと、
    /// 容器の ref(内側に入力欄がちょうど1つ。MCP は警告して撃つ)で焦点が内側の欄へ正しく移っても
    /// 点を含まないので断ってしまう。待つのは「無焦点」か「タップ前と同じ欄のまま」の間だけ
    private static func awaitClearFocusTarget(_ app: XCUIApplication, tapped: CGPoint,
                                              focusBefore: FocusMark?,
                                              refIsTextInput: Bool) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(FocusWait.waitSeconds)
        var lastElsewhere: FocusMark?
        while true {
            if let mark = focusMark(app) {
                if mark.frame.contains(tapped) || mark != focusBefore {
                    let element = focusedInput(app)
                    if element.exists { return element }
                } else {
                    lastElsewhere = mark
                }
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: FocusWait.pollSeconds)
        }
        if lastElsewhere != nil {
            throw BridgeError(422, "tapping the ref did not move keyboard focus to it within"
                + " \(FocusWait.waitSeconds)s — focus is still on another field, so clearing now"
                + " would empty that field instead")
        }
        guard !refIsTextInput else {
            // ref は入力欄型だと分かっているので「入力欄でないかも」とは言わない(事実だけ言う)
            throw BridgeError(422, "tapping the input field did not give it keyboard focus within"
                + " \(FocusWait.waitSeconds)s")
        }
        throw BridgeError(422, "nothing has keyboard focus, so there is no field to clear."
            + " If you passed a ref, it is probably not the input element itself — tapping a"
            + " container does not move focus. Tap the field (or pass the ref of the element"
            + " whose type is a text field) and try again")
    }

    /// クリアの打ち切り時間(秒)。実測では 8 文字が 3 周で空になるので、
    /// 長文でも収まるだけの余裕を持たせた上限
    private static let clearBudgetSeconds: TimeInterval = 8
    /// 残り文字数が変わらない周回の許容数。1周まるごと打鍵が落ちることがあるので 1 では早すぎる
    private static let clearMaxStagnantRounds = 4
    /// 読めない(空白のみの)内容へ撃つ当て推量の delete 本数。長さが分からないので、人や
    /// ツールが誤って残しがちな空白の連続を覆う値として 8 を置く(2026-08-31 実機実測の根拠は
    /// 直前のコメント参照)
    private static let invisibleContentDeleteBurst = 8

    /// **消去の途中で欄が消えたら、それ以上触らずに 422 で断る**。消えた要素の value / frame を読む・
    /// typeText を撃つと XCTest が失敗を記録し、数件で Tear Down してランナーごと消える(2026-09-19:
    /// WebView の中身(WebContent)を消去の途中で止めると、3 件目の失敗で Tear Down。毎回再現)。
    /// `exists` は失敗を記録しない。確認と操作の間の短い窓は残るが、失敗が重なる形は止まる
    private static func requirePresent(_ element: XCUIElement) throws {
        guard element.exists else {
            throw BridgeError(422, "the field went away while it was being cleared (the screen changed"
                + " under it — for example a web view reloaded its content). Take a fresh snapshot and try again")
        }
    }

    /// `requirePresent` を通してから `remainingText` を読む(handleClear の読み取りはすべてここを通す)
    private static func presentRemainingText(of element: XCUIElement) throws -> String? {
        try requirePresent(element)
        return remainingText(of: element)
    }

    /// value が placeholder と一致/空なら nil(クリア済み扱い)を返す
    private static func remainingText(of element: XCUIElement) -> String? {
        guard let value = element.value as? String, !value.isEmpty else { return nil }
        if let placeholder = element.placeholderValue, value == placeholder { return nil }
        return value
    }
}
