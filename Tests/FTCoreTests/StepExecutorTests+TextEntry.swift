import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

// StepExecutorTests のテキスト入力系(type/pressEnter/hideKeyboard/keyboard判定/clearInput)

extension StepExecutorTests {
    // MARK: - 施策3: substring 誤検知の fallback exact 上書き(tap アクション経路)

    /// primary が label 部分一致(substring)でしか解決できないとき、fallback に完全一致(exact)が
    /// あれば fallback で act する(in-app label がシステム UI label の部分文字列 → 誤検知の抑止)
    func testTapPrefersFallbackExactOverPrimarySubstring() async throws {
        let log = CallLog()
        // primary: "ログイン" を含むが完全一致でない(部分一致のみ)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[labeled(ref: 1, label: "ログインに失敗しました")]])
        // fallback: "ログイン" の完全一致
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 2, label: "ログイン")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        // 部分一致は記法で明示する(素の "ログイン" は完全一致なので primary に当たらない)
        let step = FlowStep(action: "tap",
                            locator: FlowLocator(label: "ログイン", labelMatch: .contains))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("fallback exact 解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("fallback.tap(ref:2)"),
                      "fallback の exact 要素で act すべき: \(log.entries)")
        XCTAssertFalse(log.entries.contains("primary.tap(ref:1)"),
                       "primary の substring 要素で act してはいけない(誤検知): \(log.entries)")
    }

    /// **システムダイアログの形**: iOS の権限ダイアログは SpringBoard が別プロセスで
    /// 描くので、**アプリ側の木には1件も現れない**。inapp モードではこのとき fallbackDriver
    /// (SystemUIDriver = springboard 参照)だけが持っているので、`tap("許可")` は
    /// フォールバック経由で解決して**そちらのドライバで撃つ**必要がある。
    ///
    /// 既存の fallback テストは「primary にも何かある」形(substring vs exact)しか見ておらず、
    /// **primary が空**というこの形は未カバーだった。docs/commands.md §システムダイアログ(iOS)
    /// が「inapp モードなら普通に書ける」と約束している経路の砦
    func testTapResolvesViaFallbackWhenPrimaryTreeHasNothing() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 7, label: "許可")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "許可"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("fallback だけが持つ要素での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("fallback.tap(ref:7)"),
                      "システムダイアログのボタンは fallback のドライバで撃つこと: \(log.entries)")
    }

    /// primary が substring 一致で fallback に exact が無ければ、primary の substring 一致で act する
    /// (fallback は1回照会するが上書きしない)
    func testTapKeepsPrimarySubstringWhenFallbackHasNoExact() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[labeled(ref: 1, label: "ログインに失敗しました")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "tap",
                            locator: FlowLocator(label: "ログイン", labelMatch: .contains))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary substring 解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.tap(ref:1)"),
                      "fallback に exact が無ければ primary substring で act すべき: \(log.entries)")
        XCTAssertEqual(fallback.snapshotCallCount, 1, "substring 一致では fallback を1回照会する")
    }

    /// primary が完全一致(exact)のときは fallback を一切照会しない(コスト増を避ける契約)
    func testTapExactPrimaryNeverQueriesFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[labeled(ref: 1, label: "ログイン")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 2, label: "ログイン")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "ログイン"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary exact 解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(fallback.snapshotCallCount, 0, "primary exact のとき fallback は照会しない")
        XCTAssertTrue(log.entries.contains("primary.tap(ref:1)"), "primary で act すべき: \(log.entries)")
    }

    /// primary に要素があれば fallbackDriver は一度も呼ばれないこと
    func testExistsResolvedByPrimaryNeverQueriesFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary 即解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(fallback.snapshotCallCount, 0)
    }

    // MARK: - type の XCUITest ルーティング

    /// preferTypeDriver(Compose 検出)時は primary を試さず typeDriver で type すること
    func testTypePrefersTypeDriverWhenComposeDetected() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_email")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[textField(ref: 2, id: "field_email")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: true, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        guard let snapIdx = log.entries.firstIndex(of: "typedriver.snapshot"),
              let typeIdx = log.entries.firstIndex(of: "typedriver.type(ref:2)") else {
            XCTFail("typedriver.snapshot → typedriver.type(ref:2) が見当たらない: \(log.entries)")
            return
        }
        XCTAssertLessThan(snapIdx, typeIdx)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") },
                       "primary.type が呼ばれてはいけない: \(log.entries)")
    }

    /// preferTypeDriver でも typeDriver 側で解決できなければ primary(通常経路)へ落とすこと
    func testTypeFallsToPrimaryWhenTypeDriverCannotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_email")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: true, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary フォールバックでの passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.type(ref:1)"),
                      "typeDriver が解決できないとき primary.type すべき: \(log.entries)")
    }

    // MARK: - type の "\n" 振り分け(iOS Return 既定挙動への統一)

    /// ロケータ有り: text に "\n" を含めば preferTypeDriver=false でも typeDriver を優先すること
    func testTypeRoutesToTypeDriverWhenTextContainsNewline() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_note")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[textField(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_note"), text: "hi\n")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("typedriver.type(ref:2)"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") },
                       "\\n を含む text は primary を試さず typeDriver へ回すべき: \(log.entries)")
    }

    /// ロケータ有り: text に "\n" が無ければ preferTypeDriver=false のとき従来どおり primary を使うこと
    func testTypeUsesPrimaryWhenTextHasNoNewline() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_note")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[textField(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_note"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.type(ref:1)"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver.type") },
                       "\\n を含まない text で typeDriver を照会してはいけない: \(log.entries)")
    }

    /// ロケータ無し: text に "\n" を含み typeDriver があれば typeDriver(ref: nil)へ回すこと。
    /// snapshot を挟まない経路なので呼び出しは type 単発のみ
    func testTypeWithoutLocatorRoutesToTypeDriverWhenTextContainsNewline() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", text: "hi\n")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries, ["typedriver.type(ref:nil)"],
                       "ロケータ無し + \\n は typeDriver(ref: nil)へ直接回すべき: \(log.entries)")
    }

    /// ロケータ無し: typeDriver が無い(Android 相当)なら "\n" を含んでいても primary へ素通しすること
    func testTypeWithoutLocatorUsesPrimaryWhenNoTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", text: "hi\n")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries, ["primary.type(ref:nil)"],
                       "typeDriver 無しでは \\n を含んでいても primary へ素通しすべき: \(log.entries)")
    }

    /// 文中(末尾でない)の "\n" でも typeDriver へ回ること(末尾限定のロジックにしない)
    func testTypeRoutesToTypeDriverWhenNewlineIsMidString() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_note")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[textField(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_note"), text: "line1\nline2")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("typedriver.type(ref:2)"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") },
                       "文中の \\n でも typeDriver へ回すべき(末尾限定ではない): \(log.entries)")
    }

    // MARK: - type の読み返し検証(verifiesTypedText == false のドライバだけ発動)

    /// verifiesTypedText == true(xcuitest/Android 相当)では読み返しスナップショットを増やさないこと
    func testTypeSkipsReadbackWhenDriverAlreadyVerifies() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field")]])
        // verifiesTypedText は既定 true(FakeAppDriver の既定。AppDriver 既定の false とは逆)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1,
                       "検証済みドライバでは読み返しの追加 snapshot を撮らないこと")
    }

    /// 一発で期待どおりに入る場合: 追加 snapshot 1枚だけで成功し、注記は付かない
    func testTypeVerifiesReadbackOnFirstTry() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "hi")]])
        primary.verifiesTypedText = false
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("一致した読み返しでは passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback)
        XCTAssertEqual(primary.snapshotCallCount, 2, "読み返しは追加 snapshot 1枚で足りること")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 1,
                       "一発で一致すれば追送/削除は要らない")
    }

    /// 1回目の読みが前方一致で止まる(取りこぼし)場合: 足りない分だけ追送して成功すること
    func testTypeResendsMissingCharactersOnPartialCommit() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "h")]])
        primary.verifiesTypedText = false
        // 1回目の type(hi そのもの)では値遷移させない —— このフックは全 type/clearInput 呼び出しで
        // 発火するので、追送(2回目以降)のときだけ「値が hi に落ち着いた」を表現する
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            guard mutations > 1 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "field", value: "hi")])
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("追送後に一致すれば passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 2,
                       "取りこぼした分を1回だけ追送すること: \(log.entries)")
    }

    /// **追送は読み返しで撮り直した木の番号で撃つ**(in-app も最後の snapshot の表しか持たない)。番号がずれた木で
    /// 元の番号のまま追送すると別の欄へ入る
    func testTypeResendsWithTheRefFromTheReadbackTree() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "other", value: nil),
                               inputField(ref: 4, id: "field", value: "h")]])
        primary.verifiesTypedText = false
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            guard mutations > 1 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "other", value: nil),
                                             self.inputField(ref: 4, id: "field", value: "hi")])
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("追送後に一致すれば passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:") },
                       ["primary.type(ref:1)", "primary.type(ref:4)"],
                       "最初は解決時の番号・追送は撮り直した木の番号: \(log.entries)")
    }

    /// 読みが期待値を超えて長い(二重入力)場合: clearInput してから全文を打ち直して成功すること
    func testTypeDeletesExcessAndRetypesOnDoubleCommit() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "hihi")]])
        primary.verifiesTypedText = false
        // 1回目の type(hi そのもの)では値遷移させない(resend テストと同じ理由)。
        // clearInput+再送の2回(mutations 2,3回目)が終わってから hi に落ち着かせる
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            guard mutations > 2 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "field", value: "hi")])
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("削除+再送後に一致すれば passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:1)"),
                      "過剰入力は clearInput で削ること: \(log.entries)")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 2,
                       "削除後に全文を再送すること: \(log.entries)")
    }

    /// マスク欄など加工された値(前方一致でも超過でもない)は検証不能として受理すること
    /// (パスワード欄の伏せ字が典型)
    func testTypeAcceptsUnverifiableValueWithoutRetry() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "••")]])
        primary.verifiesTypedText = false
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("検証不能な値は受理して passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 1,
                       "検証不能なら追送しないこと: \(log.entries)")
    }

    /// 値が停滞したまま収束しない場合: ステップを失敗させ、失敗理由に入力値そのものを含めないこと
    func testTypeFailsWhenValueNeverSettles() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "h")]])
        primary.verifiesTypedText = false
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            XCTFail("値が収束しなければ failed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertFalse(reason.contains("hi"), "失敗理由に入力値そのものを含めないこと: \(reason)")
    }

    // MARK: - type(replace:)

    /// replace: true は type の前に clearInput を1回だけ呼ぶこと(retype ではなく置換)
    func testTypeWithReplaceClearsBeforeTyping() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: "old")],
                              [inputField(ref: 1, id: "field", value: nil)]])
        // verifiesTypedText 既定 true(呼び出し順だけを見るテストなので読み返しは起こさない)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        let clearIndex = log.entries.firstIndex(of: "primary.clearInput(ref:1)")
        let typeIndex = log.entries.firstIndex { $0.hasPrefix("primary.type(ref:1)") }
        XCTAssertNotNil(clearIndex, "replace は type の前に clearInput を呼ぶこと: \(log.entries)")
        XCTAssertNotNil(typeIndex)
        if let clearIndex, let typeIndex {
            XCTAssertLessThan(clearIndex, typeIndex, "clearInput は type より前であること: \(log.entries)")
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.clearInput(ref:1)") }.count, 1,
                       "clearInput は1回だけであること: \(log.entries)")
    }

    /// **消去の後に撮り直した木の番号で打つ**。ブリッジは撮るたびに ref の表を作り直すので、消去の事後確認で撮った後に
    /// 撃つ前の番号で打つと別の欄へ入る(実測 E2E-CMP S0040 の xcuitest: 番号が振り直されて元の番号がパスワード欄を指し、
    /// xyz がパスワード欄へ入ったのに置き換えは成功と返った)
    func testTypeWithReplaceTypesWithTheRefFromTheTreeTakenAfterClearing() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field_single", value: "abc"),
                                inputField(ref: 2, id: "field_password", value: nil)],
                               // 消去の後: 先頭に別の要素が増えて番号がずれ、1 はパスワード欄を指す
                               [inputField(ref: 1, id: "field_password", value: nil),
                                inputField(ref: 3, id: "field_single", value: nil)]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_single"), text: "xyz", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:1)"), "消去は撮る前の番号(まだ正しい)で撃つ: \(log.entries)")
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.type(ref:3)") },
                      "打鍵は消去の後の木の番号で撃つ: \(log.entries)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(ref:1)") },
                       "撃つ前の番号で打つと別の欄へ入る: \(log.entries)")
        XCTAssertTrue(outcome.driverFallback?.contains("replaced the field's prior content") == true,
                      "前の値は消去の前に控える(引き直した要素は空): \(outcome.driverFallback ?? "nil")")
    }

    /// **ラベルで指したロケータは、消去の後に現れるヒントの文字に当たりうる**(欄を空にするとヒントが別の staticText として
    /// 木に出る実装がある)。引き直しは型が同じ要素だけを採り、ヒントの文字へは打たない
    func testTypeWithReplaceDoesNotRetargetToTheHintTextAfterClearing() async throws {
        let log = CallLog()
        let frame = FTRect(x: 16, y: 318, width: 370, height: 57)
        let field = ElementInfo(ref: 1, type: "textField", identifier: nil, label: "単一行", value: "abc",
                                placeholder: nil, enabled: true, frame: frame, depth: 0)
        let hint = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "単一行", value: nil,
                               placeholder: nil, enabled: true, frame: FTRect(x: 32, y: 334, width: 60, height: 24), depth: 1)
        let emptied = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true, frame: frame, depth: 0)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[field], [hint, emptied]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(label: "単一行"), text: "xyz", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:") }, ["primary.type(ref:2)"],
                       "ヒントの文字(ref 1)ではなく同じ枠の欄(ref 2)へ打つ: \(log.entries)")
    }

    /// 消去の後の木で対象を引き直せなければ打たずに失敗する(別の欄へ打つよりよい)
    func testTypeWithReplaceRefusesWhenTheFieldIsGoneAfterClearing() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field_single", value: "abc")],
                               [inputField(ref: 1, id: "field_password", value: nil)]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_single"), text: "xyz", replace: true)

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("nothing was typed"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(ref:") }, "\(log.entries)")
    }

    /// clear 後も残存値が消えない(typeDriver も無い)場合は type を撃たずに失敗させること。
    /// 空にできていないのに書き足すと、検証したのと違う値になるため
    func testTypeWithReplaceFailsWithoutTypingWhenClearLeavesResidualValue() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: "still there")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("clear が効かなければ type を撃たず failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("still there"), "残った値をメッセージに含めるべき: \(message)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(ref:") },
                       "clear に失敗したら type を撃ってはいけない: \(log.entries)")
    }

    /// **ロケータなし `type(text, replace: true)` も clear を通ること**。この形は
    /// ロケータ有りとは別の分岐(フォーカス中要素へ ref: nil で撃つ経路)を通るので、
    /// ここを覆わないと片方だけ無言で追記に戻る
    func testTypeWithoutLocatorWithReplaceClearsFocusedElementFirst() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        // pre-snapshot はフォーカス要素の有無を見るための下ごしらえ(clearInput ロケータなし版と同じ)
        XCTAssertEqual(log.entries,
                       ["primary.snapshot", "primary.clearInput(ref:nil)", "primary.type(ref:nil)"],
                       "ロケータなしの replace も clear → type の順で撃つこと: \(log.entries)")
    }

    /// ロケータなしの replace も、焦点のある欄が木に無ければ消えたかを読み返せないと注記で言う
    /// (clearInput ロケータなし版と同じヘルパを通る = 片方だけ黙らない)
    func testTypeWithoutLocatorWithReplaceNotesAnUnverifiedClear() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog())
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "type", text: "new", replace: true))

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(outcome.notes.contains(.clearInputUnverified), "読み返せなかったことを黙った")
        XCTAssertTrue(outcome.driverFallback?.contains(StepNote.clearInputUnverified.text) == true,
                      "\(outcome.driverFallback ?? "nil")")
    }

    /// ロケータなしで replace を指定しなければ clearInput を呼ばないこと(上の裏側)
    func testTypeWithoutLocatorWithoutReplaceNeverClears() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", text: "new")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries, ["primary.type(ref:nil)"],
                       "replace 未指定では clear もその下ごしらえの snapshot も撃たないこと: \(log.entries)")
    }

    /// replace: false(既定・未指定)は今までどおり clearInput を一切呼ばないこと(退行防止)
    func testTypeWithoutReplaceNeverCallsClearInput() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", value: "old")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.clearInput(") },
                       "replace 未指定では clearInput を呼んではいけない(退行防止): \(log.entries)")
    }

    /// **replace の読み返し期待値は `text` だけ**(既存値を連結しない)。ここが誤って
    /// `existingValue + text` のままだと、前方一致の取りこぼし("ne")は expected("oldnew")との
    /// prefix 関係を持たないため TypeReadback.plan が `.unverifiable` と判定し、追送せず黙って
    /// 受理してしまう(取りこぼしたまま成功したことになる)。expected が正しく "new" であれば
    /// "ne" は前方一致として認識され、追送("w")を経て "new" に収束する ―― この追送が
    /// **実際に起きること**(type 呼び出しが2回になること)で expected の値を間接的に確かめる
    func testTypeWithReplaceVerifiesAgainstTextAloneNotPriorPlusText() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [
                [inputField(ref: 1, id: "field", value: "old")],   // 解決(クリア前の値)
                [inputField(ref: 1, id: "field", value: nil)],     // clear 事後検証: 消えている
                [inputField(ref: 1, id: "field", value: "ne")],    // type 直後の読み返し: 取りこぼし
            ])
        primary.verifiesTypedText = false
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            // clearInput(1回目)・初回 type(2回目)では値を進めない。追送(3回目)で "new" に収束させる
            guard mutations > 2 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "field", value: "new")])
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("追送→収束で passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 2,
                       "expected が \"new\" でなければ「ne」は検証不能として即受理され、追送は"
                           + "起きないはず(expected が誤って \"oldnew\" だとここが1のまま): \(log.entries)")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.clearInput(ref:1)") }.count, 1)
    }

    // MARK: - pressEnter(ロケータ無し。type(ref: nil) と同じくロケータ解決を挟まない経路)
    // 以下は焦点待ち(awaitFocusBeforeKeyInput)を通るので、409/typeDriver 切替の検証は
    // primary 側に focused 要素を用意して即進行させる(待ち自体は下の MARK で別途検証する)

    /// 1枚目から focused な要素があれば、焦点確認は1回で足りすぐ実行すること
    func testPressEnterWithImmediateFocusChecksOnceThenExecutes() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pressEnter の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback, "既に焦点があるので注記は付かない")
        XCTAssertEqual(log.entries, ["primary.snapshot", "primary.pressEnter"],
                       "焦点確認は1回で足りること")
    }

    /// 409(inapp が Compose 以外の入力欄/フォーカス無しで返す)はリアクティブに typeDriver へ
    /// 切り替えること(type の 409 フォールバックと同じ形)
    func testPressEnter409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        primary.pressEnterError = DriverError.badResponse(status: 409, body: "not compose")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries,
                       ["primary.snapshot", "primary.pressEnter(throws)", "typedriver.pressEnter"])
    }

    /// 409 以外のエラーは typeDriver へ切り替えず、そのまま失敗させること
    func testPressEnterNon409DoesNotUseTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        primary.pressEnterError = DriverError.badResponse(status: 500, body: "server error")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("409 以外は失敗のままを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver") },
                       "409 以外で typeDriver を照会してはいけない: \(log.entries)")
    }

    /// typeDriver が無い場合、409 はそのまま伝播して失敗させること
    func testPressEnter409WithoutTypeDriverPropagates() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        primary.pressEnterError = DriverError.badResponse(status: 409, body: "not compose")
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("typeDriver 無しでの 409 失敗を期待したが \(outcome.status) だった")
            return
        }
    }

    // MARK: - pressEnter の焦点待ち(awaitFocusBeforeKeyInput。MCP の awaitFocus と値を共有)

    /// 1枚目は focused なし・2枚目で focused あり → 実行され、snapshot は2回以上呼ばれ、警告なし
    func testPressEnterWaitsForFocusThenExecutesWithoutWarning() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", focused: false)],
                              [inputField(ref: 1, id: "field", focused: true)]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pressEnter の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback, "焦点が立ったので注記は付かない")
        XCTAssertGreaterThanOrEqual(log.entries.filter { $0 == "primary.snapshot" }.count, 2)
        XCTAssertEqual(log.entries.last, "primary.pressEnter")
    }

    /// **どこにも** focused == true が立たないまま(pressEnter に特定の対象は無いので、
    /// 判定は「木のどこかが focused か」— DSL の awaitFocusBeforeKeyInput 参照)→
    /// タイムアウト後に実行され、警告注記が driverFallback に載る。実時間 waitSeconds(1.5s)を払う
    func testPressEnterTimesOutWithWarningWhenFocusNeverArrives() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", focused: false)]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("タイムアウトしても拒否せず実行されることを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback?.contains("took focus"), true, "\(outcome.driverFallback ?? "nil")")
        XCTAssertEqual(log.entries.last, "primary.pressEnter", "拒否せず実行まで進むこと")
    }

    // MARK: - tap 直後のロケータ無し・改行入り type の焦点待ち(awaitFocusBeforeKeyInput)

    /// tap の直後に `type("…\n")`(XCUITest へ直行し、読み返しも焦点救済も通らない)は、打つ前に焦点を確かめる。
    /// 焦点が立っていれば 1 枚読んで打ち、注記は付かない
    func testNewlineTypeRightAfterTapChecksFocusBeforeTyping() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "field")))
        let tapIndex = try XCTUnwrap(log.entries.lastIndex { $0.hasPrefix("primary.tap") }, "\(log.entries)")
        let outcome = await executor.execute(FlowStep(action: "type", text: "pqr\n"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let afterTap = Array(log.entries[(tapIndex + 1)...])
        let typeIndex = try XCTUnwrap(afterTap.firstIndex(of: "typedriver.type(ref:nil)"), "\(afterTap)")
        XCTAssertTrue(afterTap[..<typeIndex].contains("primary.snapshot"), "打つ前に焦点を確かめていない: \(afterTap)")
        XCTAssertNil(outcome.driverFallback, "焦点が立っているので注記は付かない")
    }

    /// 焦点が来ないまま待ちが尽きても拒否せずに打ち、注記を残す(pressEnter と同じ。実時間 waitSeconds を払う)
    func testNewlineTypeRightAfterTapTypesWithWarningWhenFocusNeverArrives() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: false)]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "field")))
        let outcome = await executor.execute(FlowStep(action: "type", text: "pqr\n"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(log.entries.last, "typedriver.type(ref:nil)", "拒否せず打つ")
        XCTAssertEqual(outcome.driverFallback?.contains("took focus"), true, "\(outcome.driverFallback ?? "nil")")
        XCTAssertEqual(outcome.driverFallback?.contains("before type"), true, "\(outcome.driverFallback ?? "nil")")
    }

    // MARK: - hideKeyboard(ロケータ無し。pressEnter と同じくロケータ解決を挟まない経路)

    func testHideKeyboardCallsDriverDirectlyWithoutSnapshot() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
        let step = FlowStep(action: "hideKeyboard")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("hideKeyboard の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.hideKeyboard"), "\(log.entries)")
    }

    // MARK: - keyboardIsShown / keyboardIsNotShown(ロケータ無し。開閉アニメーションを待つポーリング)

    /// キーボードが非表示→表示へ変わる過渡を、即失敗にせず timeout まで待って pass すること
    /// (1回のスナップショット照会だけだとフレークする契約の検証)
    func testKeyboardShownPollsUntilShown() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.keyboardShownFrames = [false, true]
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "keyboardShown", timeout: 3)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("表示に変わったら pass するはず"); return
        }
        XCTAssertGreaterThan(primary.snapshotCallCount, 1, "1回の照会で決めず、状態変化までポーリングすること")
    }

    /// keyboardShown の裏返し: 表示→非表示へ変わる過渡を待って pass すること
    func testKeyboardNotShownPollsUntilHidden() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.keyboardShownFrames = [true, false]
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "keyboardNotShown", timeout: 3)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("非表示に変わったら pass するはず"); return
        }
        XCTAssertGreaterThan(primary.snapshotCallCount, 1, "1回の照会で決めず、状態変化までポーリングすること")
    }

    /// keyboardShown が nil(判定不能: Android の旧ブリッジ・captureKeyboardStateOnNextSnapshot
    /// 未着火の両方であり得る)のとき、非表示への嘘の成功にせず明示的に failed で返すこと
    /// (nil を false 扱いすると keyboardIsNotShown が誤った緑で通ってしまう)
    func testKeyboardShownFailsWhenStateUnknown() async throws {
        let log = CallLog()
        // keyboardShownFrames を設定しない → SnapshotResponse.keyboardShown は常に nil
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "keyboardShown", timeout: 0)

        guard case .failed(let message) = await executor.execute(step).status else {
            XCTFail("状態を取得できないときは failed のはず"); return
        }
        XCTAssertTrue(message.contains("cannot determine"), "\(message)")
    }

    // MARK: - clearInput

    /// clearInput(セレクタあり) → 解決した ref で driver.clearInput が呼ばれること
    func testClearInputWithSelectorUsesResolvedRef() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 7, id: "field_note")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("clearInput の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:7)"),
                      "解決した ref でクリアすべき: \(log.entries)")
    }

    /// clearInput(ロケータなし) → clearInput(ref: nil)。pre-snapshot(実装2の事後検証の下ごしらえ。
    /// フォーカス要素の有無を見るために必ず撮る)はフォーカス要素が無いので、後段の事後検証は
    /// スキップして従来どおり成功する
    func testClearInputWithoutLocatorClearsFocusedElement() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("clearInput の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries, ["primary.snapshot", "primary.clearInput(ref:nil)"],
                       "ロケータ解決は挟まないが、事後検証の下ごしらえの pre-snapshot は1回撮る")
    }

    /// clearInput で primary が 409(対象なし)→ typeDriver 側の clearInput が呼ばれ、
    /// ステータスは passed + driverFallback になること
    func testClearInput409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_note")]])
        primary.clearInputError = DriverError.badResponse(status: 409, body: "no focused input")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[textField(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        // 末尾の typedriver.snapshot は事後検証(フォールバック経路にも例外を作らない契約)
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.clearInput(throws)",
            "typedriver.snapshot",
            "typedriver.clearInput(ref:2)",
            "typedriver.snapshot",
        ])
    }

    /// **422 も 409 と同じ扱い**にすること。XCUITest ランナーは同じ事情(フォーカス欄が無い/
    /// 消し切れない)を 409 では返せない — 409 は SessionRecoveryDriver がセッション消失と
    /// 断定して activate を撃つため 422 に分けてある(BridgeRouter.handleClear)。
    /// ここを 409 だけに戻すと、inapp モードの in-app→XCUITest の再試行が丸ごと不発になる
    func testClearInput422FallsBackToTypeDriverLike409() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textField(ref: 1, id: "field_note")]])
        primary.clearInputError = DriverError.badResponse(
            status: 422, body: "フォーカスされた入力欄がありません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[textField(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("422 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("typedriver.clearInput(ref:2)"),
                      "422 でも typeDriver へ回すこと: \(log.entries)")
    }

    /// **対象が確実に入力欄でない(button)+ 自前描画でないと確定**しているときは、409 でも
    /// typeDriver へ撃ち直さない(type ケースと同じ判定。TypeReadback.isPositivelyNonTextInput の doc)
    func testClearInput409WithConfirmedNonSelfRenderedButtonTargetFailsWithoutRetrying() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_submit")]])
        primary.clearInputError = DriverError.badResponse(status: 409, body: "no focused input")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "btn_submit")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables(),
                                    uiFramework: .uikit)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "btn_submit"))

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("ボタンへの 409 は撃ち直さず failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("button"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver") },
                       "確実に入力欄でない対象では typeDriver を照会してはいけない: \(log.entries)")
    }

    /// `type(replace: true)` の pre-clear も同じ門を通ること(performClearInput は clearInput
    /// ケースと replace 前処理の両方が通る共有経路 = ClearOutcome の doc)
    func testTypeWithReplaceButtonTargetFailsWithoutRetryingWhenClearInput409sWithConfirmedNonSelfRendered() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_submit")]])
        primary.clearInputError = DriverError.badResponse(status: 409, body: "no focused input")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "btn_submit")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables(),
                                    uiFramework: .uikit)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "btn_submit"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("ボタンへの replace-clear 409 は撃ち直さず failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("button"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver") },
                       "確実に入力欄でない対象では typeDriver を照会してはいけない: \(log.entries)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(ref:") },
                       "clear の門で断ったら type 自体も撃ってはいけない: \(log.entries)")
    }

    /// ロケータ無し版でも 409 は typeDriver(ref: nil)へフォールバックすること(pressEnter と同じ形)。
    /// pre-snapshot(実装2の下ごしらえ)は 409 の前に必ず1回撮る
    func testClearInputWithoutLocator409FallsBackToTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.clearInputError = DriverError.badResponse(status: 409, body: "no focused input")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback,
                       "fell back to XCUITest / " + StepNote.clearInputUnverified.text,
                       "焦点のある欄が木に無いので、切替後も読み返せなかったと言う")
        XCTAssertEqual(log.entries,
                       ["primary.snapshot", "primary.clearInput(throws)", "typedriver.clearInput(ref:nil)"])
    }

    // MARK: - clearInput の事後検証(実装2: ブリッジが 200 を返しても消えていない場合の保険)

    /// clearInput(セレクタあり)成功後、同じ driver の snapshot で値が残っていることが分かったら
    /// typeDriver へフォールバックし、そちらで消えていれば passed になること
    func testClearInputWithSelectorFallsBackWhenResidualValueRemains() async throws {
        let log = CallLog()
        // **残存 = クリア前後で同じ値**(値が変わっていれば消えたと見なす契約。placeholder が
        // value に出る実装があるため一致判定では見ない)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 7, id: "field_note", value: "residual")],
            [inputField(ref: 7, id: "field_note", value: "residual")],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [
            [inputField(ref: 2, id: "field_note", value: "residual")],
            [inputField(ref: 2, id: "field_note", value: nil)],
        ])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("残存値検出→フォールバック成功による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:7)"))
        XCTAssertTrue(log.entries.contains("typedriver.clearInput(ref:2)"),
                      "残存値が消えるまで typeDriver へフォールバックすべき: \(log.entries)")
    }

    /// clearInput(セレクタあり)で primary・typeDriver 双方とも値が残っていれば failed になり、
    /// メッセージに残存値を含めること
    func testClearInputWithSelectorFailsWhenValueRemainsAfterFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 7, id: "field_note", value: "still there")],
            [inputField(ref: 7, id: "field_note", value: "still there")],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [
            [inputField(ref: 2, id: "field_note", value: "still there")],
            [inputField(ref: 2, id: "field_note", value: "still there")],
        ])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("両ドライバとも残存値がある場合は failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("still there"), "残った値をメッセージに含めるべき: \(message)")
    }

    /// clearInput(セレクタあり)成功後、value が placeholder と一致(= iOS の空欄が value に
    /// placeholder を返す実測仕様。空欄扱い)なら typeDriver へフォールバックしないこと
    func testClearInputWithSelectorSkipsFallbackWhenValueMatchesPlaceholder() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 7, id: "field_note", value: "old")],
            [inputField(ref: 7, id: "field_note", value: "type here", placeholder: "type here")],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("空(placeholder 一致)なら passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertNil(outcome.driverFallback, "フォールバックしてはいけない: \(log.entries)")
        XCTAssertEqual(typeDriver.snapshotCallCount, 0, "typeDriver 側は一切呼ばれないはず")
    }

    /// clearInput(ロケータなし)成功後、クリア前に覚えたフォーカス要素を事後 snapshot で identifier
    /// で突き合わせ、値が残っていれば typeDriver へフォールバックすること
    func testClearInputWithoutLocatorMatchesFocusedElementByIdentifierAndFallsBack() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 1, id: "field_note", value: "residual", focused: true)],
            [inputField(ref: 1, id: "field_note", value: "residual", focused: true)],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("残存値検出→typeDriver フォールバックによる passed を期待したが \(outcome.status) だった");
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertFalse(outcome.notes.contains(.clearInputUnverified), "読み返せたのに検証不能と言った")
        XCTAssertTrue(log.entries.contains("typedriver.clearInput(ref:nil)"),
                      "残存値が消えるまで typeDriver へフォールバックすべき: \(log.entries)")
    }

    /// clearInput(ロケータなし)成功時、フォーカス要素が特定できなければ事後検証をスキップし
    /// 成功のまま**読み返せなかったことを注記で言う**(検証できないことを失敗にしない・黙って緑にもしない。
    /// 実機 iPhone SE3 の CMP: キーボードでパスワード欄が木から消え、消えていない欄が黙って緑になった)
    func testClearInputWithoutLocatorSkipsVerificationWhenNoFocusedElement() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 1, id: "other_field", value: "unrelated")],
        ])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("検証不能時は passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(outcome.notes.contains(.clearInputUnverified), "読み返せなかったことを黙った")
        XCTAssertEqual(outcome.driverFallback, StepNote.clearInputUnverified.text)
        XCTAssertEqual(primary.snapshotCallCount, 1,
                       "フォーカス要素が無ければ事後 snapshot は撮らないはず: \(log.entries)")
    }


    /// **確実に入力欄でない対象(ネイティブ描画のボタン)へは、type を撃つ前に断る** —— ドライバは打つ前に
    /// 対象をタップするので、撃つと送信ボタン等を押してしまう(nonTextInputPreflightRefusal の doc)
    func testTypeIntoConfirmedNativeButtonIsRefusedBeforeAnyTap() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_input_submit")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .uikit)
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "btn_input_submit"),
                                                      text: "hello"))
        guard case .failed(let message) = outcome.status else {
            XCTFail("ボタンへの type は撃つ前に断るはずが \(outcome.status)"); return
        }
        XCTAssertTrue(message.contains("refusing before anything is typed"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(") },
                       "断ったのに type を撃った: \(log.entries)")
    }

    /// **中心がソフトキーボードの下にある対象へは、副作用の無い手段でキーボードを閉じてから撃つ**(ユーザー決定
    /// 「人ができる操作はツールも最善を尽くす」。reachPastKeyboard の doc)。実測の形(iOS・Compose の住所フォーム):
    /// キーボード (0,538 402x336) の下に電話番号の欄 (16,619 370x65)。iOS はキーボードの上の空きを叩いて閉じる
    func testTapTypeAndClearInputUnderTheKeyboardCloseItFirst() async throws {
        for action in ["tap", "type", "clearInput"] {
            let log = CallLog()
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[Self.phoneUnderKeyboard]])
            primary.keyboardFrame = FTRect(x: 0, y: 538, width: 402, height: 336)
            primary.tapProbeAnswer = TapProbeResponse(background: true, receiver: "UIView", reason: nil)
            primary.afterCoordinateTap = { primary.keyboardFrame = nil }
            let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .compose)
            let outcome = await executor.execute(FlowStep(action: action, locator: FlowLocator(id: "field_phone"),
                                                          text: action == "type" ? "09012345678" : nil))
            XCTAssertEqual(primary.coordinateTaps.count, 1, "\(action): キーボードの上の空きを1回叩くはず")
            XCTAssertLessThan(try XCTUnwrap(primary.coordinateTaps.first).y, 538, action)
            XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.\(action)(") }, "\(action): 閉じた後に撃っていない: \(log.entries)")
            XCTAssertTrue(outcome.driverFallback?.contains("the target was under it") == true,
                          "\(action): \(outcome.driverFallback ?? "nil")")
        }
    }

    /// 副作用の無い手段で閉じなければ撃たずに失敗(Enter は欄の確定操作なので勝手に撃たない = ユーザー決定)
    func testTapTypeAndClearInputUnderAKeyboardThatWillNotCloseFailWithoutPressingEnter() async throws {
        for action in ["tap", "type", "clearInput"] {
            let log = CallLog()
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[Self.phoneUnderKeyboard]])
            primary.keyboardFrame = FTRect(x: 0, y: 538, width: 402, height: 336)
            primary.tapProbeAnswer = TapProbeResponse(background: true, receiver: "UIView", reason: nil)
            let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2),
                                        uiFramework: .compose)
            let outcome = await executor.execute(FlowStep(action: action, locator: FlowLocator(id: "field_phone"),
                                                          text: action == "type" ? "09012345678" : nil))
            guard case .failed(let message) = outcome.status else {
                XCTFail("\(action): 閉じないキーボードの下へは撃たないはずが \(outcome.status)"); continue
            }
            XCTAssertTrue(message.contains("could not be closed without side effects"), message)
            XCTAssertTrue(message.contains("pressEnter()"), message)
            XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(") || $0.hasPrefix("primary.clearInput(")
                || $0.hasPrefix("primary.tap(") || $0.hasPrefix("primary.pressEnter") },
                           "\(action): 撃った・Enter を送った: \(log.entries)")
        }
    }

    /// Android の窓がキーボードの上へ縮んで対象が木に無いときは、見つからないと言う前に閉じて探し直す
    /// (矩形の無い `keyboardShown` だけの申告でも同じ = 実機の住所フォームの形)
    func testAndroidTargetBelowAShrunkenWindowIsReachedByHidingTheKeyboard() async throws {
        for reportsFrame in [true, false] {
            let log = CallLog()
            let city = ElementInfo(ref: 1, type: "textField", identifier: "field_city", label: nil, value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 20, y: 400, width: 360, height: 50),
                                   depth: 1)
            let save = ElementInfo(ref: 2, type: "button", identifier: "btn_save", label: "保存", value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 20, y: 700, width: 360, height: 50),
                                   depth: 1)
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[city]])
            if reportsFrame {
                primary.keyboardFrame = FTRect(x: 0, y: 450, width: 400, height: 350)
            } else {
                primary.keyboardShownFrames = [true]
            }
            primary.afterHideKeyboard = {
                primary.keyboardFrame = nil
                primary.keyboardShownFrames = [false]
                primary.snapshotElements = [[city, save]]
            }
            let executor = StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_save")))
            guard case .passed = outcome.status else { XCTFail("frame=\(reportsFrame): \(outcome.status) \(log.entries)"); continue }
            XCTAssertEqual(log.entries.filter { $0 == "primary.hideKeyboard" }.count, 1, log.entries.description)
            XCTAssertTrue(log.entries.contains("primary.tap(ref:2)"), log.entries.description)
            XCTAssertTrue(outcome.driverFallback?.contains("not on the screen while the keyboard was up") == true,
                          outcome.driverFallback ?? "nil")
        }
    }

    private static let phoneUnderKeyboard = ElementInfo(
        ref: 1, type: "textView", identifier: "field_phone", label: "電話番号", value: nil, placeholder: nil, enabled: true,
        frame: FTRect(x: 16, y: 619, width: 370, height: 65), depth: 1)

    /// キーボードの上に見えている欄へは従来どおり打つ(門は覆われた欄だけ)
    func testTypeIntoAFieldAboveTheKeyboardStillTypes() async throws {
        let log = CallLog()
        let line = ElementInfo(ref: 1, type: "textView", identifier: "field_address_line", label: "番地", value: nil,
                               placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 474, width: 370, height: 64),
                               depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[line]])
        primary.keyboardFrame = FTRect(x: 0, y: 538, width: 402, height: 336)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .compose)
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_address_line"),
                                                      text: "x"))
        if case .failed(let message) = outcome.status {
            XCTAssertFalse(message.contains("under the soft keyboard"), "見えている欄を断った: \(message)")
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.type(") }, "見えている欄に打っていない: \(log.entries)")
    }

    /// clearInput も同じ(ドライバは消す前に対象をタップする)
    func testClearInputOnConfirmedNativeButtonIsRefusedBeforeAnyTap() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_input_submit")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .uikit)
        let outcome = await executor.execute(FlowStep(action: "clearInput", locator: FlowLocator(id: "btn_input_submit")))
        guard case .failed(let message) = outcome.status else {
            XCTFail("ボタンへの clearInput は撃つ前に断るはずが \(outcome.status)"); return
        }
        XCTAssertTrue(message.contains("refusing before anything is cleared"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.clearInput(") },
                       "断ったのに clearInput を撃った: \(log.entries)")
    }

    /// 自前描画(Compose 等)でもボタン型へは撃つ前に断る —— 編集できる要素は全経路で入力型を名乗る
    /// (nonTextInputPreflightRefusal の doc)
    func testTypeIntoButtonTypedElementOnSelfRenderedFrameworkIsRefused() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_input_submit")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .compose)
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "btn_input_submit"),
                                                      text: "hello"))
        guard case .failed(let message) = outcome.status else {
            XCTFail("自前描画のボタンへの type も撃つ前に断るはずが \(outcome.status)"); return
        }
        XCTAssertTrue(message.contains("refusing before anything is typed"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(") }, "断ったのに type を撃った: \(log.entries)")
    }

    /// 自前描画の本物の入力欄が落ちる型は clickable(役割の確定しない受け皿)—— これは断らずに撃つ
    func testTypeIntoClickableOnSelfRenderedFrameworkIsNotRefused() async throws {
        let log = CallLog()
        let field = ElementInfo(ref: 1, type: "clickable", identifier: "field_name", label: nil, value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[field]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .compose)
        _ = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_name"), text: "hello"))
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.type(") },
                      "clickable は役割の確定しない型なので断らない: \(log.entries)")
    }

    /// 内側に入力欄がちょうど1つある容器(ボタン型の包み)は従来どおり撃つ(警告だけ)
    func testTypeIntoContainerWithOneInnerFieldIsNotRefused() async throws {
        let log = CallLog()
        let wrapper = element(ref: 1, id: "row_height")
        let field = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[wrapper, field]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .uikit)
        _ = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "row_height"), text: "170"))
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.type(") },
                      "入力欄を1つ包む容器は断らずに撃つ: \(log.entries)")
    }
}
