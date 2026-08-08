import React from 'react';
import { WebView } from 'react-native-webview';

import { WEBVIEW_HTML } from '../webviewHtml';

// ネットワークは使わない(source.html はインライン文字列)。中身の契約は webviewHtml.ts 経由の
// E2EAppCMP/docs/webview.html を参照。この画面自体には #id は無い(WebView 画面の規約)。
export function WebViewScreen() {
  return <WebView source={{ html: WEBVIEW_HTML }} style={{ flex: 1 }} />;
}
