// レーンログ表示文字列の i18n(辞書 + 専用ランタイム)。
//
// runReducer.ts / runLaneModel.ts はこのモジュールを使う。両ファイルは webview バンドルにも
// 含まれる(webview/monitor/laneLog.js が runLaneModel の定数を import → runLaneModel が
// runReducer の STATUS_MARK を import)。そのため vscode を引き込む i18n/index.ts は使えない。
// この module は core.ts と自前 dict のみに依存し、locale は各バンドルが setLaneLocale() で注入する:
//   - 拡張バンドル: i18n/index.ts の setLocaleFromConfig()
//   - webview バンドル: webview/i18n.js(document.documentElement.lang)
// tLane のキー存在は test/i18n.test.mjs が検証する(tsc の型検査対象外のため)。
import { formatMessage, type Locale, type MessageDict } from "../core";

export const laneStrings = {
  "lane.overall": { ja: "全体", en: "Overall" },
  "lane.runStarted": { ja: "▶ 実行開始({total}件)", en: "▶ Run started ({total})" },
  "lane.sceneStarted": { ja: "  シーン{scene}: {title}", en: "  Scene {scene}: {title}" },
  "lane.sceneFinished": { ja: "  {mark} シーン{scene} {label}", en: "  {mark} Scene {scene} {label}" },
  "lane.pass": { ja: "成功", en: "Passed" },
  "lane.fail": { ja: "失敗", en: "Failed" },
  "lane.fixSuggestion": { ja: "  💡 修正提案: {detail}", en: "  💡 Fix suggestion: {detail}" },
  "lane.paused": { ja: "  ⏸ 一時停止: {description}", en: "  ⏸ Paused: {description}" },
  "lane.runFinished": {
    ja: "■ 完了: 成功 {passed} / 失敗 {failed}",
    en: "■ Done: {passed} passed / {failed} failed",
  },
  "lane.requeued": {
    ja: "  🔁 {reason}のため別デバイスで再実行します({attempt}/{limit})",
    en: "  🔁 Re-running on another device due to {reason} ({attempt}/{limit})",
  },
  "lane.detailFallback": { ja: "     フォールバック: {detail}", en: "     Fallback: {detail}" },
  "lane.detailHealed": { ja: "     自己修復: {detail}", en: "     Heal: {detail}" },
  "lane.detailSkipped": { ja: "     スキップ理由: {detail}", en: "     Skip reason: {detail}" },
  "lane.failedText": { ja: "失敗しました", en: "Failed" },
  "lane.passed": { ja: "  ✅ 成功", en: "  ✅ Passed" },
  "lane.failed": { ja: "  ❌ 失敗", en: "  ❌ Failed" },
  "lane.reportSuffix": { ja: " — レポート: {path}", en: " — report: {path}" },
  "lane.scenarioFailedText": { ja: "シナリオが失敗しました", en: "The scenario failed" },
  "lane.reportParen": { ja: "(レポート: {path})", en: "(report: {path})" },
} satisfies MessageDict;

let locale: Locale = "ja";

/** レーン i18n の locale を設定する。拡張/webview の各バンドルが起動時に注入する。 */
export function setLaneLocale(next: Locale): void {
  locale = next;
}

const lookup: MessageDict = laneStrings;

/** レーン表示文字列を引く。未登録キーはキー文字列をそのまま返す。 */
export function tLane(key: string, params?: Record<string, string | number>): string {
  const entry = lookup[key];
  if (!entry) {
    return key;
  }
  return formatMessage(entry[locale], params);
}

/** 逐次実行(worker なし)をまとめる「全体」レーンの表示名(locale 依存のため関数)。 */
export function overallLaneName(): string {
  return tLane("lane.overall");
}
