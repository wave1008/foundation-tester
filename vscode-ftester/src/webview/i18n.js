// webview 側の i18n ランタイム。locale は HTML の <html lang="..."> 属性から判定する
// (extension 側 renderHtml が currentLocale() を埋める)。辞書は webview 用 strings を直接読む
// (esbuild が .ts を解決してバンドルする。laneLog.js が runLaneModel.ts を読むのと同じ)。
// 全 webview モジュールはここから t を import する: import { t } from '../i18n.js'
//
// 契約: 参照する core.ts / strings/*.ts は vscode 非依存であること。呼び出しキーの存在は
// test/i18n.test.mjs が検証する(webview .js は tsc の型検査対象外のため)。

import { formatMessage } from '../i18n/core';
import { setLaneLocale } from '../i18n/strings/lane';
import { webviewMonitorAStrings } from '../i18n/strings/webviewMonitorA';
import { webviewMonitorBStrings } from '../i18n/strings/webviewMonitorB';
import { webviewDashboardStrings } from '../i18n/strings/webviewDashboard';

const merged = {
  ...webviewMonitorAStrings,
  ...webviewMonitorBStrings,
  ...webviewDashboardStrings,
};

const locale = document.documentElement.lang === 'ja' ? 'ja' : 'en';

// レーンログ用の別ランタイム(runLaneModel/runReducer が使う。laneLog.js 経由で webview バンドルに
// 含まれる)へ locale を伝える。ここは monitor バンドル init 時に1回走る。
setLaneLocale(locale);

export function t(key, params) {
  const entry = merged[key];
  if (!entry) {
    return key;
  }
  return formatMessage(entry[locale], params);
}
