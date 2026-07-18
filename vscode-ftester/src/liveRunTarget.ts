// liveRunTarget.ts
// livePanel.ts の prepareForRun が返し、runHandler.ts の executeRun が --platform/--port/--serial の
// 引数構築に使う契約。単一デバイスを直接指定する ftester api run 呼び出し用(--profile とは排他)。

export interface LiveRunTarget {
  readonly platform: "ios" | "android";
  readonly serial?: string;
  readonly port?: number;
  readonly udid?: string;
}
