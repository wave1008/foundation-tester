// extension 側の i18n ランタイム。t() で辞書を引き、locale は ftester.language 設定
// (auto/ja/en)から解決する。auto は vscode.env.language に追従。
// webview 側は別ランタイム(src/webview/i18n.js)で、辞書 core.ts と webview 用 strings を直接読む。
//
// 契約:
// - モジュールロード時に vscode API を呼ばない(esbuild.mjs の vscodeStubPlugin が Proxy を返すため、
//   ロード時に getConfiguration().get() すると Proxy が locale に化ける)。config 読みは関数内限定。
// - 未初期化時の既定 locale は "ja"(既存テストは initI18n を呼ばず、現行の日本語文言をアサートする)。

import * as vscode from "vscode";
import { formatMessage, type Locale, type MessageDict } from "./core";
import { setLaneLocale } from "./strings/lane";
import { deviceOpsStrings } from "./strings/deviceOps";
import { exploreHealStrings } from "./strings/exploreHeal";
import { liveStrings } from "./strings/live";
import { monitorStrings } from "./strings/monitor";
import { panelsStrings } from "./strings/panels";
import { profilesStrings } from "./strings/profiles";
import { runStrings } from "./strings/run";
import { workbenchStrings } from "./strings/workbench";

// extension バンドルに含まれる全辞書(webview 専用の strings は含めない。webview 側で別途マージ)。
const merged = {
  ...profilesStrings,
  ...panelsStrings,
  ...monitorStrings,
  ...liveStrings,
  ...deviceOpsStrings,
  ...runStrings,
  ...workbenchStrings,
  ...exploreHealStrings,
};

/** 全辞書のキー和集合。t() の第1引数はこの型に制約され、typo を tsc がコンパイル時に検出する。 */
export type MessageKey = keyof typeof merged;

const lookup: MessageDict = merged;

let locale: Locale = "ja";

export function currentLocale(): Locale {
  return locale;
}

/** キーの現在 locale の訳文を返す。params があれば {name} を置換。未登録キーはキー文字列をそのまま返す。 */
export function t(key: MessageKey, params?: Record<string, string | number>): string {
  const entry = lookup[key];
  if (!entry) {
    return key;
  }
  return formatMessage(entry[locale], params);
}

function computeLocale(): Locale {
  const setting = vscode.workspace.getConfiguration("ftester").get<string>("language", "auto");
  if (setting === "ja" || setting === "en") {
    return setting;
  }
  // auto: VS Code の表示言語に追従(ja 系なら日本語、それ以外は英語)。
  return vscode.env.language.toLowerCase().startsWith("ja") ? "ja" : "en";
}

/** ftester.language 設定と vscode.env.language から現在 locale を再計算して反映する。 */
export function setLocaleFromConfig(): void {
  locale = computeLocale();
  // レーンログ用の別ランタイム(vscode 非依存・webview と共有)にも同じ locale を伝える。
  setLaneLocale(locale);
}

/** activate() 冒頭で1回呼び、起動時 locale を確定する。 */
export function initI18n(): void {
  setLocaleFromConfig();
}
