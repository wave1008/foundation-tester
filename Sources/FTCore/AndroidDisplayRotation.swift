// AndroidDisplayRotation.swift
// `adb shell dumpsys window displays` の出力から、最初のディスプレイの「前面が要求している向き」
// (`mLastOrientation` = ActivityInfo.SCREEN_ORIENTATION_*)と表示の回転(`mRotation`)を読む純粋パーサと、
// 回転の指示がアプリの宣言で断られるかの判定。AndroidDriver.rotate が使う。
// **宣言が向きを固定しているなら待っても回らない**(ランチャーは nosensor = 5 で、user_rotation を
// 書いても表示は 0 のまま。実測 Pixel 9 emulator / Pixel 3a・4a)ので、期限まで待たずに断れる。

import Foundation

public enum AndroidDisplayRotation {

    public struct State: Equatable, Sendable {
        /// 前面が要求している向き(SCREEN_ORIENTATION_*)。読めなければ nil
        public let requestedOrientation: Int?
        /// 表示の回転(Surface.ROTATION_* = 0...3)。読めなければ nil
        public let rotation: Int?

        public init(requestedOrientation: Int?, rotation: Int?) {
            self.requestedOrientation = requestedOrientation
            self.rotation = rotation
        }
    }

    /// 最初の `Display: mDisplayId=` ブロックだけを読む(折りたたみ端末などの2枚目を混ぜない)。
    /// `mRotation=ROTATION_0` の形(構成のダンプ)は数えず、行頭の `mRotation=<数字>` だけを採る
    public static func parse(_ dumpsys: String) -> State {
        let lines = dumpsys.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Display: mDisplayId=") }) else {
            return State(requestedOrientation: nil, rotation: nil)
        }
        var requested: Int?
        var rotation: Int?
        for line in lines[(start + 1)...] {
            if line.hasPrefix("Display: mDisplayId=") { break }
            if requested == nil, line.hasPrefix("mLastOrientation=") {
                requested = leadingInt(line.dropFirst("mLastOrientation=".count))
            }
            if rotation == nil, line.hasPrefix("mRotation=") {
                rotation = leadingInt(line.dropFirst("mRotation=".count))
            }
        }
        return State(requestedOrientation: requested, rotation: rotation)
    }

    /// 前面の宣言がこの向きを禁じているときの理由(禁じていない・不明なら nil = 待つ側)。
    /// 縦専用(1/7/9/12)へ横を、横専用(0/6/8/11)へ縦を求めたとき、および nosensor(5)/ locked(14)で
    /// 表示がまだ目標でないとき(どちらも user_rotation に従わない)
    public static func refusal(requestedOrientation: Int, rotation: Int?, wantsLandscape: Bool) -> String? {
        let name = orientationName(requestedOrientation)
        if wantsLandscape, portraitOnly.contains(requestedOrientation) {
            return "the app in front requests a portrait-only orientation (\(name)), so it does not rotate to landscape"
        }
        if !wantsLandscape, landscapeOnly.contains(requestedOrientation) {
            return "the app in front requests a landscape-only orientation (\(name)), so it does not rotate to portrait"
        }
        if ignoresUserRotation.contains(requestedOrientation),
           let rotation, (rotation % 2 == 1) != wantsLandscape {
            return "the app in front requests \(name), which does not follow the rotation fleetest sets"
                + " (the display stays at rotation \(rotation))"
        }
        return nil
    }

    static let portraitOnly: Set<Int> = [1, 7, 9, 12]
    static let landscapeOnly: Set<Int> = [0, 6, 8, 11]
    static let ignoresUserRotation: Set<Int> = [5, 14]

    public static func orientationName(_ value: Int) -> String {
        let names = [-1: "unspecified", 0: "landscape", 1: "portrait", 2: "user", 3: "behind", 4: "sensor",
                     5: "nosensor", 6: "sensorLandscape", 7: "sensorPortrait", 8: "reverseLandscape",
                     9: "reversePortrait", 10: "fullSensor", 11: "userLandscape", 12: "userPortrait",
                     13: "fullUser", 14: "locked"]
        return names[value].map { "\($0) = \(value)" } ?? "\(value)"
    }

    private static func leadingInt(_ text: Substring) -> Int? {
        let digits = text.prefix { $0 == "-" || $0.isNumber }
        return Int(digits)
    }
}
