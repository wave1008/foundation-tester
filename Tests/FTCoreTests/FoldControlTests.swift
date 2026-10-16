import FTCore
import XCTest

/// 開閉の判定と手順(DSL の fold / unfold / hinge と MCP の ft_fold が共有)。
/// 観測の入力は実測の形(Xcode 27.2 beta 3 の devicectl・Pixel 9 Pro Fold の Emulator と Pixel 3a の device_state)
final class FoldControlTests: XCTestCase {

    // MARK: - iOS(devicectl)

    private func displays(_ list: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["result": ["displays": list]])
    }

    private func integrated(_ name: String, _ size: [Int], active: Bool?) -> [String: Any] {
        var d: [String: Any] = ["name": name, "nativeSize": size, "type": ["integrated": [:] as [String: Any]]]
        if let active { d["active"] = active }
        return d
    }

    func testDuoShowingTheOuterScreenIsFolded() {
        let data = displays([integrated("LCD", [1398, 2034], active: true),
                             integrated("LCD-1", [2007, 2853], active: false)])
        XCTAssertEqual(FoldControl.observe(fromDevicectlJSON: data), .state(.folded))
    }

    func testDuoShowingTheInnerScreenIsUnfolded() {
        let data = displays([integrated("LCD", [1398, 2034], active: false),
                             integrated("LCD-1", [2007, 2853], active: true)])
        XCTAssertEqual(FoldControl.observe(fromDevicectlJSON: data), .state(.unfolded))
    }

    /// 単画面の機種は active 欄を持たない(iPhone 17 Pro の実測)
    func testSingleDisplayIsNotFoldable() {
        let data = displays([integrated("LCD", [1206, 2622], active: nil)])
        XCTAssertEqual(FoldControl.observe(fromDevicectlJSON: data), .notFoldable)
    }

    /// 画面の電源を simctl で触ると active 欄ごと消える(実測)= 読めない。推測で片方に倒さない
    func testMissingActiveFlagsAreUnreadable() {
        let data = displays([integrated("LCD", [1398, 2034], active: nil),
                             integrated("LCD-1", [2007, 2853], active: nil)])
        guard case .unknown = FoldControl.observe(fromDevicectlJSON: data) else {
            return XCTFail("two built-in displays without an active one must be unreadable")
        }
    }

    // MARK: - Android(device_state)

    private let foldableStates = """
        Supported states: [
          DeviceState{identifier=0, name='CLOSED', app_accessible=true, cancel_when_requester_not_on_top=false},
          DeviceState{identifier=1, name='HALF_OPENED', app_accessible=true, cancel_when_requester_not_on_top=false},
          DeviceState{identifier=2, name='OPENED', app_accessible=true, cancel_when_requester_not_on_top=false},
          DeviceState{identifier=3, name='REAR_DISPLAY_MODE', app_accessible=true, cancel_when_requester_not_on_top=false},
        ]
        """

    private func android(_ states: String, current: String) -> String {
        states + "\n" + FoldControl.androidStateSeparator + "\n" + current + "\n"
    }

    func testAndroidFoldablePostures() {
        XCTAssertEqual(FoldControl.observe(androidDeviceState: android(foldableStates, current: "0")), .state(.folded))
        XCTAssertEqual(FoldControl.observe(androidDeviceState: android(foldableStates, current: "1")), .state(.unfolded))
        XCTAssertEqual(FoldControl.observe(androidDeviceState: android(foldableStates, current: "2")), .state(.unfolded))
        guard case .unknown = FoldControl.observe(androidDeviceState: android(foldableStates, current: "3")) else {
            return XCTFail("rear display mode is neither folded nor unfolded")
        }
    }

    /// 折りたたみでない端末は DEFAULT だけ(物理の Pixel 3a の実測)
    func testAndroidWithoutAClosedStateIsNotFoldable() {
        let states = "Supported states: [\n  DeviceState{identifier=0, name='DEFAULT'},\n]"
        XCTAssertEqual(FoldControl.observe(androidDeviceState: android(states, current: "0")), .notFoldable)
    }

    // MARK: - 手順

    /// 観測を順に返す偽物(最後の値を返し続ける)
    private final class Observations: @unchecked Sendable {
        private var queue: [FoldObservation]
        private(set) var sent: [Double] = []
        init(_ queue: [FoldObservation]) { self.queue = queue }
        func next() -> FoldObservation { queue.count > 1 ? queue.removeFirst() : queue[0] }
        func send(_ degrees: Double) { sent.append(degrees) }
    }

    func testUnfoldSendsTheOpenAngleAndWaitsForTheSwitch() async throws {
        let fake = Observations([.state(.folded), .state(.folded), .state(.unfolded)])
        var remembered: FoldState?
        let outcome = try await FoldControl.apply(.unfold, waitSeconds: 5, send: { fake.send($0) },
                                                  observe: { fake.next() }, sent: { remembered = $0 })
        XCTAssertEqual(fake.sent, [180])
        XCTAssertEqual(outcome, FoldControl.Outcome(before: .folded, after: .unfolded))
        XCTAssertEqual(remembered, .folded)
    }

    /// 切り替わらなければ赤(黙って緑にしない)。送った後の失敗でも元の状態は控えられている
    func testFoldThatNeverSwitchesFailsAndStillRemembersTheOriginal() async {
        let fake = Observations([.state(.unfolded)])
        var remembered: FoldState?
        do {
            _ = try await FoldControl.apply(.fold, waitSeconds: 0.3, send: { fake.send($0) },
                                            observe: { fake.next() }, sent: { remembered = $0 })
            XCTFail("must throw")
        } catch let failure as FoldControl.Failure {
            XCTAssertEqual(failure, .didNotSwitch(expected: .folded, observed: .state(.unfolded), waitedSeconds: 0.3))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(fake.sent, [0])
        XCTAssertEqual(remembered, .unfolded)
    }

    /// 折りたたみ機でない・読めないときは送らない
    func testNothingIsSentWhenTheStateCannotBeRead() async {
        for observation in [FoldObservation.notFoldable, .unknown("x")] {
            let fake = Observations([observation])
            do {
                _ = try await FoldControl.apply(.unfold, waitSeconds: 1, send: { fake.send($0) },
                                                observe: { fake.next() }, sent: { _ in })
                XCTFail("must throw for \(observation)")
            } catch {}
            XCTAssertEqual(fake.sent, [], "\(observation)")
        }
    }

    /// 角度の指定は画面を確かめない(途中の角度は履歴で変わる)。範囲外は送らない
    func testAngleIsSentWithoutExpectingAScreenAndOutOfRangeIsRefused() async throws {
        let fake = Observations([.state(.folded), .state(.folded)])
        let outcome = try await FoldControl.apply(.angle(130), waitSeconds: 0, send: { fake.send($0) },
                                                  observe: { fake.next() }, sent: { _ in })
        XCTAssertEqual(fake.sent, [130])
        XCTAssertEqual(outcome, FoldControl.Outcome(before: .folded, after: .folded))
        do {
            _ = try await FoldControl.apply(.angle(181), waitSeconds: 0, send: { fake.send($0) },
                                            observe: { fake.next() }, sent: { _ in })
            XCTFail("must throw")
        } catch let failure as FoldControl.Failure {
            XCTAssertEqual(failure, .outOfRange(181))
        }
        XCTAssertEqual(fake.sent, [130])
    }

    func testRestoreTargetOnlyWhenTheStateDiffers() {
        XCTAssertNil(FoldControl.restoreTarget(original: nil, current: .unfolded))
        XCTAssertNil(FoldControl.restoreTarget(original: .folded, current: .folded))
        XCTAssertEqual(FoldControl.restoreTarget(original: .folded, current: .unfolded), .fold)
        XCTAssertEqual(FoldControl.restoreTarget(original: .unfolded, current: .folded), .unfold)
        // 今の状態が読めなければ元の状態へ送り直す(戻し忘れより送り直しのほうが害が小さい)
        XCTAssertEqual(FoldControl.restoreTarget(original: .folded, current: nil), .fold)
    }
}
