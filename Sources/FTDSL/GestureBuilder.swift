// GestureBuilder.swift
// `gesture { }` の結果ビルダー。FTFinger(FTCore)を1本/配列/ループ/分岐で並べて [FTFinger] へ畳むだけ
// (SwiftUI の ViewBuilder と同じ形の配列ビルダー)。妥当性の検査はここでは行わない
// (TouchGesture.validate に集約する)。

import FTCore

@resultBuilder
public enum FTGestureBuilder {
    public static func buildBlock(_ components: [FTFinger]...) -> [FTFinger] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ finger: FTFinger) -> [FTFinger] { [finger] }
    public static func buildExpression(_ fingers: [FTFinger]) -> [FTFinger] { fingers }

    public static func buildArray(_ components: [[FTFinger]]) -> [FTFinger] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [FTFinger]?) -> [FTFinger] { component ?? [] }

    public static func buildEither(first component: [FTFinger]) -> [FTFinger] { component }
    public static func buildEither(second component: [FTFinger]) -> [FTFinger] { component }
}
