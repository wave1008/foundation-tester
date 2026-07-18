// i18n の型と純関数。**vscode に依存しない**(webview バンドルからも import されるため。
// runLaneModel.ts と同じ制約)。extension 側ランタイムは i18n/index.ts、webview 側は
// src/webview/i18n.js。

export type Locale = "ja" | "en";

export interface MessageEntry {
  readonly ja: string;
  readonly en: string;
}

export type MessageDict = Record<string, MessageEntry>;

/**
 * {name} 形式の名前付きプレースホルダを params で置換する。params に無いキーはそのまま残す
 * (訳文の {0} 等の誤りを黙って空にしないため)。ja/en で同じプレースホルダ集合を持つことは
 * test/i18n.test.mjs が検証する。
 */
export function formatMessage(
  template: string,
  params?: Record<string, string | number>,
): string {
  if (!params) {
    return template;
  }
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : match,
  );
}
