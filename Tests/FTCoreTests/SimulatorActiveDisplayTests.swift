import FTCore
import XCTest

/// `devicectl device info displays --json-output -` の実測の形(Xcode 27.2 beta 3)で固定する
final class SimulatorActiveDisplayTests: XCTestCase {
    private func json(_ displays: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["info": [:], "result": ["displays": displays]])
    }

    private func integrated(id: Int, name: String, size: [Int], active: Bool?) -> [String: Any] {
        var d: [String: Any] = ["displayId": id, "name": name, "nativeSize": size,
                                "type": ["integrated": [:] as [String: Any]]]
        if let active { d["active"] = active }
        return d
    }

    /// iPhone Duo(閉じた状態): 外側 LCD が表示中・内側 LCD-1 は消灯
    func testFoldablePicksTheActiveIntegratedDisplay() {
        let data = json([
            integrated(id: 1, name: "LCD", size: [1398, 2034], active: true),
            integrated(id: 3, name: "LCD-1", size: [2007, 2853], active: false),
        ])
        XCTAssertEqual(SimulatorActiveDisplay.select(fromDevicectlJSON: data),
                       .init(displayID: 1, pixelWidth: 1398, pixelHeight: 2034))
    }

    /// 開いた状態(内側が表示中)は内側を選ぶ —— 主画面に固定すると黒い外側を撮る
    func testFoldableOpenedPicksTheInnerDisplay() {
        let data = json([
            integrated(id: 1, name: "LCD", size: [1398, 2034], active: false),
            integrated(id: 3, name: "LCD-1", size: [2007, 2853], active: true),
        ])
        XCTAssertEqual(SimulatorActiveDisplay.select(fromDevicectlJSON: data)?.displayID, 3)
    }

    /// 単画面の機種(iPhone 17 Pro の実測は active 欄自体が無い)は指定しない = 従来どおり
    func testSingleDisplayNeedsNoArgument() {
        let data = json([integrated(id: 1, name: "LCD", size: [1206, 2622], active: nil)])
        XCTAssertNil(SimulatorActiveDisplay.select(fromDevicectlJSON: data))
    }

    /// 外部画面(integrated でない)は数えない —— 数えると「内蔵2枚・表示中1枚」に見えて TVOut を撮る
    func testExternalDisplaysAreNotCounted() {
        let data = json([
            integrated(id: 1, name: "LCD", size: [1206, 2622], active: nil),
            ["displayId": 2, "name": "TVOut", "nativeSize": [720, 480], "active": true,
             "type": ["tvOut": [:] as [String: Any]]],
        ])
        XCTAssertNil(SimulatorActiveDisplay.select(fromDevicectlJSON: data))
    }

    /// 表示中が1枚に決まらないときは推測で片方を選ばない
    func testAmbiguousActiveStateSelectsNothing() {
        let none = json([
            integrated(id: 1, name: "LCD", size: [1398, 2034], active: false),
            integrated(id: 3, name: "LCD-1", size: [2007, 2853], active: false),
        ])
        let both = json([
            integrated(id: 1, name: "LCD", size: [1398, 2034], active: true),
            integrated(id: 3, name: "LCD-1", size: [2007, 2853], active: true),
        ])
        XCTAssertNil(SimulatorActiveDisplay.select(fromDevicectlJSON: none))
        XCTAssertNil(SimulatorActiveDisplay.select(fromDevicectlJSON: both))
        XCTAssertNil(SimulatorActiveDisplay.select(fromDevicectlJSON: Data("not json".utf8)))
    }
}
