// streamVisibilityLog.ts
// モニターの配信を動かす2条件(パネルが見えている・「ライブ更新」)の
// **切り替わり**を出力へ1行残すための判定(vscode 非依存の純粋関数。文言は呼び手 monitorPanel.ts が t() で作る)。
// 畳むときの破棄は意図的なので配信側は何も言わず、run と重なると「run が配信を止めた・戻らない」と
// 取り違えた(maintainer-notes §63.4)。

export interface StreamVisibilityInputs {
  readonly panelVisible: boolean;
  readonly showStreamDuringRun: boolean;
}

export type StreamFoldReason = "panelHidden" | "liveUpdateOff";

export type StreamVisibilityChange =
  | { readonly kind: "folded"; readonly reasons: readonly StreamFoldReason[] }
  | { readonly kind: "resumed" };

export function streamVisible(inputs: StreamVisibilityInputs): boolean {
  return inputs.panelVisible && inputs.showStreamDuringRun;
}

/** 前回 setVisible へ渡した値(未適用は undefined)と今の入力から、言うべき切り替わりを返す。
 * **初回(undefined)と変化なしは言わない**(タブを開くたび・2秒ごとの当て直しで行を積まない) */
export function streamVisibilityChange(previous: boolean | undefined,
                                       inputs: StreamVisibilityInputs): StreamVisibilityChange | undefined {
  const visible = streamVisible(inputs);
  if (previous === undefined || previous === visible) {
    return undefined;
  }
  if (visible) {
    return { kind: "resumed" };
  }
  const reasons: StreamFoldReason[] = [];
  if (!inputs.panelVisible) reasons.push("panelHidden");
  if (!inputs.showStreamDuringRun) reasons.push("liveUpdateOff");
  return { kind: "folded", reasons };
}
