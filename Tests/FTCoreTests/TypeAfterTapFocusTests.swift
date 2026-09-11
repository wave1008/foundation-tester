// `tap(入力欄)` → `type("文字列")`(Shirates 伝統の書き方)が成立することの固定。
//
// Android の入力欄は容器(Material の TextInputLayout)と中身(TextInputEditText)に分かれ、
// **id は容器側に付くことが多い**。容器を叩いても入力フォーカスは中身へ移らないので、
// 素直に書くと次の type が「フォーカスが無い」で落ちていた(受け手報告)。
//
// 契約:
//   ①タップの直後で焦点が無ければ、**一意に決まる欄**へ入れ直す
//   ②焦点があるときは従来どおり(木を読み足さない = 速い経路を壊さない)
//   ③先が一意に決まらないなら**何もしない**(推測で別の欄へ入れない)

import XCTest
@testable import FTCore

final class TypeAfterTapFocusTests: XCTestCase {

    private final class RecordingDriver: AppDriver, @unchecked Sendable {
        var elements: [ElementInfo]
        private(set) var typedRefs: [Int?] = []
        private(set) var snapshotCount = 0
        /// **既定 true**(既存テストは読み返しを問題にしない救済経路だけを確かめる)。
        /// false にすると救済した type も StepExecutor+Actions の読み返し検証を通る
        var verifiesTypedText = true
        /// true の間だけ type() が要素の value を書き換える(「反映される」を表現する)。
        /// false のまま(既定)なら value は変わらない = 読み返しが永久に一致しない形を作れる
        var reflectsTypedText = false
        init(elements: [ElementInfo]) { self.elements = elements }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 1080, height: 2400),
                                    elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {
            typedRefs.append(ref)
            guard reflectsTypedText, let ref,
                  let index = elements.firstIndex(where: { $0.ref == ref }) else { return }
            elements[index].value = (elements[index].value ?? "") + text
        }
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func container(ref: Int, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 42, y: 417, width: 996, height: 147), depth: 1)
    }

    private func field(ref: Int, id: String = "textInputEditText", focused: Bool? = nil,
                       y: Double = 417, enabled: Bool = true) -> ElementInfo {
        var element = ElementInfo(ref: ref, type: "textField", identifier: id, label: nil,
                                  value: nil, placeholder: nil, enabled: enabled,
                                  frame: FTRect(x: 42, y: y, width: 996, height: 144), depth: 2)
        element.focused = focused
        return element
    }

    /// 本命: 容器を叩いた後の `type` が、中身の欄へ入る
    func testTypesIntoTheFieldWhenTheTapDidNotFocusIt() async throws {
        let driver = RecordingDriver(elements: [container(ref: 8, id: "txtMailAddress"),
                                                field(ref: 9)])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "txtMailAddress"), timeout: 1))

        let outcome = await executor.execute(FlowStep(action: "type", text: "hello"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.typedRefs, [9], "中身の欄(ref 9)へ入れること")
        XCTAssertTrue(outcome.notes.contains(.typeFocusRecovered), "救済は注記に残す")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("#textInputEditText"),
                      "どこへ入れたか名指しすること: \(outcome.driverFallback ?? "")")
    }

    /// **救済した type も読み返しを見る**(verifiesTypedText == false のときだけ)。
    /// ロケータ有り type(StepExecutor+Actions の case "type")と同じ規律 —— in-app は
    /// 「200 が返った = 入った」を保証しない。反映されないまま緑にしていた(修正前のバグ)
    func testFocusRecoveredTypeFailsWhenReadbackNeverReflectsIt() async throws {
        let driver = RecordingDriver(elements: [container(ref: 8, id: "txtMailAddress"),
                                                field(ref: 9)])
        driver.verifiesTypedText = false
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "txtMailAddress"), timeout: 1))

        let outcome = await executor.execute(FlowStep(action: "type", text: "hello"))

        guard case .failed = outcome.status else {
            return XCTFail("反映されない読み返しは failed を期待したが \(outcome.status) だった")
        }
    }

    /// 反映されれば読み返しを通って passed のまま、救済の注記も残ること
    func testFocusRecoveredTypeVerifiesReadbackWhenItReflects() async throws {
        let driver = RecordingDriver(elements: [container(ref: 8, id: "txtMailAddress"),
                                                field(ref: 9)])
        driver.verifiesTypedText = false
        driver.reflectsTypedText = true
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "txtMailAddress"), timeout: 1))

        let outcome = await executor.execute(FlowStep(action: "type", text: "hello"))

        guard case .passed = outcome.status else {
            return XCTFail("反映された読み返しは passed を期待したが \(outcome.status) だった")
        }
        XCTAssertTrue(outcome.notes.contains(.typeFocusRecovered),
                      "読み返しを通しても救済の注記は残ること")
    }

    /// 焦点があるときは**従来どおり**フォーカス中要素へ送る(木を読み足さない)
    func testKeepsTheFastPathWhenSomethingHasFocus() async throws {
        let driver = RecordingDriver(elements: [container(ref: 8, id: "txtMailAddress"),
                                                field(ref: 9, focused: true)])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "txtMailAddress"), timeout: 1))
        let snapshotsAfterTap = driver.snapshotCount

        let outcome = await executor.execute(FlowStep(action: "type", text: "hello"))

        XCTAssertEqual(driver.typedRefs, [nil], "フォーカス中要素へ送ること")
        XCTAssertFalse(outcome.notes.contains(.typeFocusRecovered))
        XCTAssertEqual(driver.snapshotCount, snapshotsAfterTap + 1,
                       "焦点の確認は1枚だけ(happy path で余分に読まない)")
    }

    /// **一意に決まらないなら何もしない**(容器の中に欄が2つあるフォーム等)
    func testDoesNotGuessWhenSeveralFieldsAreInside() async throws {
        var wide = container(ref: 8, id: "form")
        wide.frame = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let driver = RecordingDriver(elements: [wide, field(ref: 9, y: 417),
                                                field(ref: 10, id: "second", y: 700)])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "form"), timeout: 1))

        let outcome = await executor.execute(FlowStep(action: "type", text: "hello"))

        XCTAssertEqual(driver.typedRefs, [nil], "どちらへ入れるべきか言えないので従来どおり")
        XCTAssertFalse(outcome.notes.contains(.typeFocusRecovered))
    }

    /// tap 以外を挟んだら「直前のタップ」ではない(記憶を持ち越さない)
    func testForgetsTheTapAfterAnotherAction() async throws {
        let driver = RecordingDriver(elements: [container(ref: 8, id: "txtMailAddress"),
                                                field(ref: 9)])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "txtMailAddress"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        let outcome = await executor.execute(FlowStep(action: "type", text: "hello"))

        XCTAssertEqual(driver.typedRefs, [nil])
        XCTAssertFalse(outcome.notes.contains(.typeFocusRecovered))
    }

    // MARK: - 選び方(純関数)

    func testPicksTheOnlyFieldInsideTheTappedContainer() {
        let tapped = container(ref: 8, id: "txtMailAddress")
        let picked = InputFocusRescue.fieldToType(after: tapped, in: [tapped, field(ref: 9)])
        XCTAssertEqual(picked?.ref, 9)
    }

    /// 叩いたのが入力欄そのものなら、それ自身(フォーカスだけが立たなかった形)
    func testPicksTheTappedFieldItself() {
        let tapped = field(ref: 9)
        XCTAssertEqual(InputFocusRescue.fieldToType(after: tapped, in: [tapped])?.ref, 9)
    }

    /// 無効な欄は選ばない(入らないので、入れたことにしない)
    func testSkipsDisabledFields() {
        let tapped = container(ref: 8, id: "txtMailAddress")
        XCTAssertNil(InputFocusRescue.fieldToType(
            after: tapped, in: [tapped, field(ref: 9, enabled: false)]))
    }

    /// 申告が無ければ救済すべき(true)
    func testFocusElsewhereWhenNothingIsFocused() {
        let tapped = container(ref: 8, id: "txtMailAddress")
        XCTAssertTrue(InputFocusRescue.focusIsElsewhere(from: tapped, in: [tapped, field(ref: 9)]))
    }

    /// 叩いた要素そのものに焦点があるなら救済しない(フォーカスだけが立たなかった形ではない)
    func testFocusNotElsewhereWhenTheTappedElementItselfHasFocus() {
        let tapped = field(ref: 9, focused: true)
        XCTAssertFalse(InputFocusRescue.focusIsElsewhere(from: tapped, in: [tapped]))
    }

    /// 叩いた容器の**内側**に焦点があるなら救済しない(従来どおりの速い経路)
    func testFocusNotElsewhereWhenFocusIsInsideTheTappedContainer() {
        let tapped = container(ref: 8, id: "txtMailAddress")
        let inside = field(ref: 9, focused: true)
        XCTAssertFalse(InputFocusRescue.focusIsElsewhere(from: tapped, in: [tapped, inside]))
    }

    /// 叩いた容器の**外**の別の欄に焦点が残っているなら救済すべき
    /// (Android は容器を叩いても前の EditText の焦点を外さない)
    func testFocusIsElsewhereWhenFocusIsOutsideTheTappedContainer() {
        let tapped = container(ref: 8, id: "txtMailAddress")
        let outsideAndFocused = field(ref: 20, id: "single", focused: true, y: 100)
        XCTAssertTrue(InputFocusRescue.focusIsElsewhere(from: tapped, in: [tapped, outsideAndFocused]))
    }

    /// **ref は木ごとに振り直される**: タップ前の木で叩いた要素と同じ番号の、**別の**要素が撮り直した木で
    /// 焦点を持っていても「叩いた要素に焦点がある」と読まない(番号の偶然の一致で救済を止めない)
    func testACoincidentalRefMatchInTheNewTreeIsNotTheTappedElement() {
        let tapped = container(ref: 8, id: "txtMailAddress")
        let otherFieldWithTheSameRef = field(ref: 8, id: "single", focused: true, y: 100)
        XCTAssertTrue(InputFocusRescue.focusIsElsewhere(from: tapped, in: [otherFieldWithTheSameRef]))
    }

    /// 同じ要素かは id + 型で見る(ref が変わっていても、同じ id の欄に焦点があれば救済しない)
    func testTheSameElementIsRecognisedByIdEvenWithANewRef() {
        let tapped = field(ref: 9, id: "single")
        let sameFieldNewRef = field(ref: 31, id: "single", focused: true, y: 400)
        XCTAssertFalse(InputFocusRescue.focusIsElsewhere(from: tapped, in: [sameFieldNewRef]))
    }

    /// StepExecutor 経由: 別の欄に焦点を残したまま容器を叩いても、
    /// `type` は前の欄でなく叩いた容器の中身へ入ること
    func testRescuesIntoTheTappedContainerEvenWhenAnotherFieldStillHasFocus() async throws {
        let stillFocusedElsewhere = field(ref: 20, id: "single", focused: true, y: 100)
        let driver = RecordingDriver(elements: [stillFocusedElsewhere,
                                                container(ref: 8, id: "txtMailAddress"),
                                                field(ref: 9)])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap",
                                            locator: FlowLocator(id: "txtMailAddress"), timeout: 1))

        let outcome = await executor.execute(FlowStep(action: "type", text: "W3"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.typedRefs, [9],
                       "前に焦点があった別の欄(ref 20)でなく、叩いた容器の中の欄(ref 9)へ入れること")
        XCTAssertTrue(outcome.notes.contains(.typeFocusRecovered), "救済は注記に残す")
    }
}
