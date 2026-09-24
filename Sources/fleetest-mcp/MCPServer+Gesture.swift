// MCPServer+Gesture.swift
// ft_gesture の `fingers` 引数(JSON)→ GestureRequest への変換。本体は MCPServer.swift

import Foundation
import FTCore

extension MCPServer {

    /// `fingers` 引数 → `GestureRequest`。**座標は絶対**(ft_tap の x/y と同じ座標系)——
    /// DSL の `FTFinger`(対象の枠に対する比率)とは違う。MCP は撮った snapshot の対象枠を
    /// 呼び手に選ばせる仕組みを持たないので、比率にすると呼び手が自分で換算する羽目になる。
    ///
    /// 型エラー・欠落・move/hold の二重指定(または両方省略)は**指/ステップの番号を添えて**
    /// 返す(デバイスに触る前 = `driver(args)` より前に呼ぶこと)。数値そのものの妥当性
    /// (有限・非負・時刻の単調性・画面内・合計秒数の上限)は `TouchGesture.validate` に委ねる
    /// (CLAUDE.md「MCP と DSL が共有する唯一の判定」—— ここは JSON の形だけを見る)
    static func gestureRequestArgument(_ args: [String: Any]) throws -> GestureRequest {
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
        var fingers: [GestureFinger] = []
        for (fingerIndex, rawFinger) in rawFingers.enumerated() {
            let name = "finger \(fingerIndex + 1)"
            guard let finger = rawFinger as? [String: Any] else {
                throw MCPError("\(name) must be an object (got \(describeArgumentValue(rawFinger)))")
            }
            let x = try requiredGestureNumber(finger, "x", in: name)
            let y = try requiredGestureNumber(finger, "y", in: name)
            let startSeconds = try optionalGestureNumber(finger, "startSeconds", in: name) ?? 0
            var t = startSeconds
            var cx = x, cy = y
            var points = [GesturePoint(x: cx, y: cy, t: t)]
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
                    // 秒数は正の値だけ(DSL の TouchGesture.resolve と同じ規則。0 は瞬間移動になる)
                    let secondsKey = isMove ? "durationSeconds" : "holdSeconds"
                    if isMove {
                        cx = try requiredGestureNumber(step, "x", in: stepName)
                        cy = try requiredGestureNumber(step, "y", in: stepName)
                    }
                    let seconds = try requiredGestureNumber(step, secondsKey, in: stepName)
                    guard seconds.isFinite, seconds > 0 else {
                        throw MCPError("\(stepName).\(secondsKey) must be a finite number greater than 0"
                            + " (got \(seconds))")
                    }
                    t += seconds
                    points.append(GesturePoint(x: cx, y: cy, t: t))
                }
            }
            // steps 無し = ただのタップ&リフト(TouchGesture.resolve の isEmpty 分岐と同じ規約)
            if points.count == 1 {
                points.append(GesturePoint(x: cx, y: cy, t: t + TouchGesture.minimumContactSeconds))
            }
            fingers.append(GestureFinger(points: points))
        }
        return GestureRequest(fingers: fingers)
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

    /// validate を通った絶対座標の要求 → 下書き用の比率ジェスチャ(`FTFinger`)。
    /// `TouchGesture.resolve` の逆写像(比率 → 絶対)を手で戻す —— MCP は比率を持たないので
    /// screen を使って割り戻す。**同じ座標が続く区間は hold、動いた区間は move**にする
    /// (`TouchGesture.resolve` の isEmpty 分岐と往復するので、steps 無しの FTFinger を書いた場合と
    /// 実行結果が一致する。往復の最小形までは求めない — 下書きは実行できれば十分)
    static func gestureFingersForDraft(_ request: GestureRequest, screen: FTRect) -> [FTFinger] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        func ratio(_ point: GesturePoint) -> (x: Double, y: Double) {
            ((point.x - screen.x) / screen.width, (point.y - screen.y) / screen.height)
        }
        return request.fingers.compactMap { finger -> FTFinger? in
            guard let first = finger.points.first else { return nil }
            let (rx, ry) = ratio(first)
            var built = FTFinger(x: rx, y: ry, startSeconds: first.t)
            var previous = first
            for point in finger.points.dropFirst() {
                let dt = point.t - previous.t
                if point.x == previous.x, point.y == previous.y {
                    built = built.hold(seconds: dt)
                } else {
                    let (mx, my) = ratio(point)
                    built = built.move(x: mx, y: my, durationSeconds: dt)
                }
                previous = point
            }
            return built
        }
    }
}
