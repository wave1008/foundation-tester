// PaintOrder.swift
// 「どちらが手前に描かれているか」の唯一の判定。**MCP(RefGuard)と DSL(OcclusionSuspicion)が
// 共有する** —— 別々に持つと片方だけ直したときに「同じ画面で遮蔽の判定が食い違う」が起きる。
//
// **ツリーの並び順は描画順ではない**。長らく「後に出るほど手前」で近似してきたが、production では
// 裏返る —— Google マップは地図の chrome(FAB・ストリートビュー)を**シートより後**に出すのに、
// 描画はシートが手前。2026-08-07 に MCP 側でこれを踏み、`#mylocation_button` を無警告でタップして
// 裏の広告を押し、**Chrome が起動**した。
//
// **本物の順序はブリッジが送る**(`ElementInfo.z`。Android は `getDrawingOrder` を根から積んで
// 通し番号にする)。持たないエンジン(iOS の XCUITest / in-app には描画順を読む API が無い)では
// 従来どおりツリー順へ落ちる。

import Foundation

public enum PaintOrder {

    /// `candidate` が `element` より手前に描かれているか。
    ///
    /// **両方が `z` を持つときだけ z を信じる** —— 片方だけ nil の木(打ち切りや別ブリッジの混在)で
    /// 大小を比べても意味が無い。落ちる先はツリー順(`ref` は木の並びに沿って 1 から振られる)。
    public static func drawnAbove(_ candidate: ElementInfo, _ element: ElementInfo) -> Bool {
        if let candidateZ = candidate.z, let elementZ = element.z { return candidateZ > elementZ }
        return candidate.ref > element.ref
    }

    /// この木が本物の塗り順を持っているか(注記の文言を変えるときの判定用)。
    /// **1つでも欠けていれば false** —— 混在した木で「z がある」と言うと読み手を誤らせる
    public static func isReported(in elements: [ElementInfo]) -> Bool {
        !elements.isEmpty && elements.allSatisfy { $0.z != nil }
    }
}
