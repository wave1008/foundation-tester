import Foundation

/// 内蔵画面を2枚以上持つシミュレータ(折りたたみの iPhone Duo = 外側 `LCD` / 内側 `LCD-1`)で、
/// **いま表示中の画面**を選ぶ。`simctl io screenshot|recordVideo` も `devicectl device capture` も、
/// 画面の指定が無いと「Cannot choose between 2 displays」で exit 22 になる(Xcode 27.2 beta 3 で実測)。
/// **主画面(`--display=primary`)に固定しない** —— 開くとアプリは内側へ移るので、閉じた側の黒い画面を撮る。
/// 表示中かどうかは `devicectl device info displays` の `active` だけが言う(simctl の enumerate は
/// 両方とも Power state: On と答える)。単画面の機種は `active` 欄自体を持たない。
/// 同期相手: Sources/fleetest-simstream/main.m の ftActiveDisplaySize(同じ判定の ObjC 版)
public enum SimulatorActiveDisplay {
    public struct Display: Equatable, Sendable {
        /// simctl の `--display=` が受け取る Screen ID
        public let displayID: Int
        public let pixelWidth: Int
        public let pixelHeight: Int

        public init(displayID: Int, pixelWidth: Int, pixelHeight: Int) {
            self.displayID = displayID
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    /// `devicectl device info displays --json-output -` の全体 → 指定すべき画面。
    /// 内蔵画面が1枚以下なら nil(指定しない = 従来どおり)。複数あって表示中が1枚に決まらなければ nil
    /// (指定しないので simctl は exit 22 で落ち、呼び手の既存の失敗の扱いに乗る。推測で片方を撮らない)
    public static func select(fromDevicectlJSON data: Data) -> Display? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]] else { return nil }
        let integrated = displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
        guard integrated.count > 1 else { return nil }
        let active = integrated.filter { ($0["active"] as? Bool) == true }
        guard active.count == 1, let chosen = active.first,
              let id = chosen["displayId"] as? Int,
              let size = chosen["nativeSize"] as? [Int], size.count == 2 else { return nil }
        return Display(displayID: id, pixelWidth: size[0], pixelHeight: size[1])
    }

    /// 1回の問い合わせ(実測 0.14 秒・M2 Ultra)。失敗・単画面は nil
    public static func resolve(udid: String) -> Display? {
        guard let out = try? Shell.runData(
            ["xcrun", "devicectl", "device", "info", "displays", "--device", udid, "--quiet", "--json-output", "-"],
            timeout: 15), out.status == 0 else { return nil }
        return select(fromDevicectlJSON: out.data)
    }

    /// `simctl io <udid> <op>` の op の直後に足す引数(単画面・解決できないときは空)
    public static func simctlIOArguments(udid: String) -> [String] {
        resolve(udid: udid).map { ["--display=\($0.displayID)"] } ?? []
    }

    /// `simctl io screenshot`。**まず画面を指定せずに撮り、失敗したときだけ**表示中の画面を引いて撮り直す
    /// (単画面の機種は devicectl を1度も呼ばない)。fold の開閉にも毎回追従する
    public static func simctlScreenshot(udid: String, path: String, timeout: Double) -> Shell.Result? {
        let first = try? Shell.run(["xcrun", "simctl", "io", udid, "screenshot", path], timeout: timeout)
        if let first, first.status == 0 { return first }
        let display = simctlIOArguments(udid: udid)
        guard !display.isEmpty else { return first }
        return try? Shell.run(["xcrun", "simctl", "io", udid, "screenshot"] + display + [path], timeout: timeout)
    }
}
