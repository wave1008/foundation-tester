// MCPServer+Gesture.swift
// ft_gesture の `fingers` 引数(JSON)→ 絶対座標の `[FTFinger]` への変換。本体は MCPServer.swift

import Foundation
import FTCore

extension MCPServer {

    /// `fingers` 引数 → `[FTFinger]`。**座標は絶対**(ft_tap の x/y と同じ座標系)——
    /// DSL の `FTFinger`(対象の枠に対する比率)とは違う値だが、**同じ型で表せる**: 呼び手
    /// (`MCPServer+GesturesTools.swift` の `ft_gesture`)は `TouchGesture.resolve(_:in: FTRect(x:0,y:0,
    /// width:1,height:1), screen:, maxGestureSeconds:)` にそのまま渡す —— 幅1・高さ1の矩形を
    /// target にすると `resolve` の比率写像(`target.x + target.width * rx`)が恒等写像になり、
    /// 絶対座標をそのまま素通しする。**点の積み上げ・最小接触時間・秒数の妥当性検査(有限・
    /// 0より大きい)は resolve 側の仕事**(重複させない)。
    ///
    /// 型エラー・欠落・move/hold の二重指定(または両方省略)は**指/ステップの番号を添えて**
    /// 返す(デバイスに触る前 = `driver(args)` より前に呼べる形を保つ ——
    /// `resolve` は screen が要るので driver 取得後にしか呼べないが、JSON の形だけの誤りは
    /// ここで先に弾く。CLAUDE.md「MCP と DSL が共有する唯一の判定」—— ここは JSON の形だけを見る)
    static func gestureFingersArgument(_ args: [String: Any]) throws -> [FTFinger] {
        guard let raw = args["fingers"] else {
            throw MCPError("fingers is required: an array of 1-\(TouchGesture.maxFingers) finger"
                + " paths, each { x, y, startSeconds?, steps?: [{x, y, durationSeconds} or"
                + " {holdSeconds}] } — absolute coordinates, same system as ft_tap's x/y")
        }
        guard let rawFingers = raw as? [Any] else {
            throw MCPError("fingers must be an array (got \(describeArgumentValue(raw)))")
        }
        guard !rawFingers.isEmpty else {
            throw MCPError("fingers must not be empty — at least one finger path is required")
        }
        var fingers: [FTFinger] = []
        for (fingerIndex, rawFinger) in rawFingers.enumerated() {
            let name = "finger \(fingerIndex + 1)"
            guard let finger = rawFinger as? [String: Any] else {
                throw MCPError("\(name) must be an object (got \(describeArgumentValue(rawFinger)))")
            }
            let x = try requiredGestureNumber(finger, "x", in: name)
            let y = try requiredGestureNumber(finger, "y", in: name)
            let startSeconds = try optionalGestureNumber(finger, "startSeconds", in: name) ?? 0
            var built = FTFinger(x: x, y: y, startSeconds: startSeconds)
            if let rawSteps = finger["steps"] {
                guard let steps = rawSteps as? [Any] else {
                    throw MCPError("\(name).steps must be an array (got \(describeArgumentValue(rawSteps)))")
                }
                for (stepIndex, rawStep) in steps.enumerated() {
                    let stepName = "\(name), step \(stepIndex + 1)"
                    guard let step = rawStep as? [String: Any] else {
                        throw MCPError("\(stepName) must be an object (got \(describeArgumentValue(rawStep)))")
                    }
                    let isMove = step["x"] != nil || step["y"] != nil || step["durationSeconds"] != nil
                    let isHold = step["holdSeconds"] != nil
                    guard isMove || isHold else {
                        throw MCPError("\(stepName) must be either a move"
                            + " ({x, y, durationSeconds}) or a hold ({holdSeconds})")
                    }
                    guard !(isMove && isHold) else {
                        throw MCPError("\(stepName) has both move fields (x/y/durationSeconds) and"
                            + " holdSeconds — a step is one or the other, not both")
                    }
                    if isMove {
                        let mx = try requiredGestureNumber(step, "x", in: stepName)
                        let my = try requiredGestureNumber(step, "y", in: stepName)
                        let duration = try requiredGestureNumber(step, "durationSeconds", in: stepName)
                        built = built.move(x: mx, y: my, durationSeconds: duration)
                    } else {
                        let holdSeconds = try requiredGestureNumber(step, "holdSeconds", in: stepName)
                        built = built.hold(seconds: holdSeconds)
                    }
                }
            }
            fingers.append(built)
        }
        return fingers
    }

    private static func requiredGestureNumber(_ dict: [String: Any], _ key: String,
                                              in context: String) throws -> Double {
        guard let raw = dict[key] else {
            throw MCPError("\(context).\(key) is required")
        }
        guard let value = raw as? Double else {
            throw MCPError("\(context).\(key) must be a number (got \(describeArgumentValue(raw)))")
        }
        return value
    }

    private static func optionalGestureNumber(_ dict: [String: Any], _ key: String,
                                              in context: String) throws -> Double? {
        guard let raw = dict[key] else { return nil }
        guard let value = raw as? Double else {
            throw MCPError("\(context).\(key) must be a number (got \(describeArgumentValue(raw)))")
        }
        return value
    }

    /// 絶対座標の `[FTFinger]`(`gestureFingersArgument` が返した、送信前の形)→ 比率の `[FTFinger]`
    /// (DSL の gesture が書く形)。screen で割るだけ —— resolve 後の `GestureRequest`(点に展開済み)
    /// から再構築するより単純(往復して move/hold を推測し直さずに済む)
    static func gestureFingersRatio(_ fingers: [FTFinger], screen: FTRect) -> [FTFinger] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        func ratio(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            ((x - screen.x) / screen.width, (y - screen.y) / screen.height)
        }
        return fingers.map { finger in
            let (rx, ry) = ratio(finger.x, finger.y)
            var built = FTFinger(x: rx, y: ry, startSeconds: finger.startSeconds)
            for step in finger.steps {
                switch step {
                case .move(let x, let y, let durationSeconds):
                    let (mx, my) = ratio(x, y)
                    built = built.move(x: mx, y: my, durationSeconds: durationSeconds)
                case .hold(let seconds):
                    built = built.hold(seconds: seconds)
                }
            }
            return built
        }
    }
}
