// ひと続きのジェスチャ(DSL の `gesture` / MCP の `ft_gesture`)の記述と検証(純粋関数)。
// **DSL と MCP が共有する唯一の判定**。ワイヤ形は BridgeDTO の `GestureRequest`。
//
// 指の動きは**データで渡してブリッジが一括で再生する**。点ごとに HTTP を往復させると
// 往復の揺らぎ(数十 ms〜)が速度を見る recognizer を壊すため、利用者のコードに
// 「指を動かす」コールバックは渡さない。

import Foundation

/// 1本の指の経路。座標は**対象の枠に対する比率**(0...1 が枠の内側。枠の外も画面内なら可)。
/// 押す位置から始めて `move` / `hold` を順に積み、最後に離す(離す操作は書かない)。
///
///     FTFinger(x: 0.2, y: 0.5).hold(seconds: 0.8).move(x: 0.8, y: 0.5, durationSeconds: 0.4)
public struct FTFinger: Codable, Equatable, Sendable {
    public enum Step: Codable, Equatable, Sendable {
        case move(x: Double, y: Double, durationSeconds: Double)
        case hold(seconds: Double)
    }

    public var x: Double
    public var y: Double
    /// ジェスチャ開始から押すまでの秒(2本目以降の指を遅らせて置く用)
    public var startSeconds: Double
    public var steps: [Step]

    public init(x: Double, y: Double, startSeconds: Double = 0) {
        self.x = x
        self.y = y
        self.startSeconds = startSeconds
        self.steps = []
    }

    /// 指を離さずに (x, y) まで等速で動かす
    public func move(x: Double, y: Double, durationSeconds: Double) -> FTFinger {
        var copy = self
        copy.steps.append(.move(x: x, y: y, durationSeconds: durationSeconds))
        return copy
    }

    /// 指を置いたまま止まる
    public func hold(seconds: Double) -> FTFinger {
        var copy = self
        copy.steps.append(.hold(seconds: seconds))
        return copy
    }

    /// この指が離れる時刻(秒)。動きも静止も無い指は `TouchGesture.minimumContactSeconds` だけ触れる
    public var endSeconds: Double {
        let travelled = steps.reduce(0) { total, step in
            switch step {
            case .move(_, _, let seconds), .hold(let seconds): return total + seconds
            }
        }
        return startSeconds + (steps.isEmpty ? TouchGesture.minimumContactSeconds : travelled)
    }
}

public enum TouchGesture {

    /// 指の本数の上限。**装置の上限ではなく操作の意味から決めた値**(片手の指の本数。
    /// 6本以上を要する UI は無い)。上げても両ブリッジは動くが、要求の大きさだけが増える
    public static let maxFingers = 5

    /// 1本の指に置ける点の上限。根拠: Android の注入器は 16ms 刻みで再生するので、
    /// 既定の上限 10 秒では 10 / 0.016 = 625 刻み。これより細かい点は再生で間引かれて意味を持たない。
    /// 上限を `maxGestureSeconds:` で延ばしたときも点の数はこの値で縛る(要求の大きさを抑える)
    public static let maxPointsPerFinger = 625

    /// 移動も静止も無い指(= 触れて離すだけ)に置く接触時間(秒)。座標ドラッグの押下静止
    /// (`swipePointToPoint` の pressSeconds)と同じ 0.05 —— 押下と離す時刻が同じだと
    /// recognizer がタッチとして数えないことがある
    public static let minimumContactSeconds = 0.05

    /// 比率の指を `target` の枠で絶対座標へ写し、`validate` を通した要求を返す。
    /// 失敗は英語の文言(DSL の失敗メッセージ・MCP のエラーにそのまま出す)
    public static func resolve(_ fingers: [FTFinger], in target: FTRect, screen: FTRect,
                               maxGestureSeconds: Double) -> Result<GestureRequest, Rejection> {
        let request = GestureRequest(fingers: fingers.map { finger in
            func point(_ rx: Double, _ ry: Double, _ t: Double) -> GesturePoint {
                GesturePoint(x: target.x + target.width * rx, y: target.y + target.height * ry, t: t)
            }
            var t = finger.startSeconds
            var cx = finger.x, cy = finger.y
            var points = [point(cx, cy, t)]
            for step in finger.steps {
                switch step {
                case .move(let x, let y, let seconds):
                    t += seconds
                    cx = x
                    cy = y
                case .hold(let seconds):
                    t += seconds
                }
                points.append(point(cx, cy, t))
            }
            if finger.steps.isEmpty {
                points.append(point(cx, cy, t + minimumContactSeconds))
            }
            return GestureFinger(points: points)
        })
        // 秒数の誤りは比率の段で言う(写した後だと「点 n の時刻」になり、書いた引数と対応しない)
        for (index, finger) in fingers.enumerated() {
            guard finger.startSeconds.isFinite, finger.startSeconds >= 0 else {
                return .failure(Rejection("finger \(index + 1): startSeconds must be a finite,"
                    + " non-negative number (got \(finger.startSeconds))"))
            }
            for step in finger.steps {
                switch step {
                case .move(_, _, let seconds) where !(seconds.isFinite && seconds > 0):
                    return .failure(Rejection("finger \(index + 1): durationSeconds of move must be"
                        + " a finite number greater than 0 (got \(seconds))"))
                case .hold(let seconds) where !(seconds.isFinite && seconds > 0):
                    return .failure(Rejection("finger \(index + 1): seconds of hold must be"
                        + " a finite number greater than 0 (got \(seconds))"))
                default:
                    break
                }
            }
        }
        return validate(request, screen: screen, maxGestureSeconds: maxGestureSeconds)
    }

    /// 絶対座標の要求を検査する(MCP はここを直接通る)。**ブリッジへ送る前の唯一の門**
    public static func validate(_ request: GestureRequest, screen: FTRect,
                                maxGestureSeconds: Double) -> Result<GestureRequest, Rejection> {
        guard !request.fingers.isEmpty else {
            return .failure(Rejection("a gesture needs at least one finger"))
        }
        guard request.fingers.count <= maxFingers else {
            return .failure(Rejection("a gesture can use at most \(maxFingers) fingers"
                + " (got \(request.fingers.count))"))
        }
        for (index, finger) in request.fingers.enumerated() {
            let name = "finger \(index + 1)"
            guard finger.points.count >= 2 else {
                return .failure(Rejection("\(name) needs at least two points (where it touches down"
                    + " and where it lifts)"))
            }
            guard finger.points.count <= maxPointsPerFinger else {
                return .failure(Rejection("\(name) has \(finger.points.count) points; at most"
                    + " \(maxPointsPerFinger) are allowed"))
            }
            var previous = -Double.infinity
            for (n, p) in finger.points.enumerated() {
                guard p.x.isFinite, p.y.isFinite, p.t.isFinite else {
                    return .failure(Rejection("\(name), point \(n + 1): coordinates and time"
                        + " must be finite numbers"))
                }
                guard p.t >= 0, p.t >= previous else {
                    return .failure(Rejection("\(name), point \(n + 1): time must not go"
                        + " backwards (got \(p.t) after \(previous))"))
                }
                previous = p.t
                // 画面の外は Android では注入が断られ、iOS では画面の縁のシステムジェスチャに化けうる
                guard p.x >= screen.x, p.x <= screen.x + screen.width,
                      p.y >= screen.y, p.y <= screen.y + screen.height else {
                    return .failure(Rejection("\(name), point \(n + 1) (\(format(p.x)), \(format(p.y)))"
                        + " is off the screen (\(format(screen.width)) x \(format(screen.height)))"))
                }
            }
            guard finger.points.last!.t > finger.points.first!.t else {
                return .failure(Rejection("\(name) lifts at the moment it touches down"))
            }
        }
        if let violation = BridgeAPI.gestureSecondsViolation(
            subject: "the total duration of gesture", seconds: request.totalSeconds,
            cap: maxGestureSeconds) {
            return .failure(Rejection(violation))
        }
        return .success(request)
    }

    public struct Rejection: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    private static func format(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f" : "%.1f", value)
    }
}
