// WebView 画面に読ませる HTML の唯一の正は E2EAppCMP/docs/webview.html。この定数はその写し
// (byte 一致)。他 SUT と同じく、ここは差分を作らない。
export const WEBVIEW_HTML = `<!doctype html>
<!--
  WebView 画面の中身の正本。docs/ui-contract.md の「WebView 画面」節と対になる。
  4 SUT がそれぞれ同じ内容を持つ(iOS/CMP は文字列定数、Android/Flutter はアセット)。
  **id 属性はテストからは引けない**(HTML の id は iOS/Android とも a11y の identifier に
  現れない。2026-07-29 実測)。テストが指すのは表示テキストと aria-label だけ。
  id はこのファイル内の JS が参照するためだけに置いている。
-->
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, system-ui, sans-serif; font-size: 17px; margin: 0; padding: 16px; }
  h1 { font-size: 22px; }
  a, button, input { font-size: 17px; }
  /* 44px 未満はタップ判定が不安定。行は 56px 以上(Compose iOS の frame クランプ対策と同じ理由) */
  button, input { min-height: 44px; padding: 8px; box-sizing: border-box; }
  input { width: 90%; }
  .row { min-height: 56px; padding: 8px 0; border-bottom: 1px solid #ccc; }
</style>
</head>
<body>
<h1 id="wv_title">WebView 見出し</h1>
<p id="wv_text">WebView 本文</p>
<p><a id="wv_link" href="javascript:void(0)" onclick="setResult('link')">WebView リンク</a></p>
<p><input id="wv_input" type="text" placeholder="WebView 入力"></p>
<p><button id="wv_submit" onclick="setResult(document.getElementById('wv_input').value)">送信</button></p>
<p><button id="wv_aria" aria-label="WebView アリアラベル" onclick="setResult('aria')"><span aria-hidden="true">&#9679;</span></button></p>
<!-- 座標検証の材料(DOM 経路は getBoundingClientRect を画面座標へ写す。transform を無視すると
     60px 右へずれてタップが外れる = ボタン半幅より大きい移動量にしてある。動かすと退行検知が消える -->
<p><button id="wv_transform" style="transform: translate(60px, 0)" onclick="setResult('transform')">変形ボタン</button></p>
<p id="wv_result">wv_result=-</p>
<div id="wv_rows"></div>
<p id="wv_offscreen">WebView 画面外テキスト</p>
<!-- 座標検証の材料: fixed はスクロール後も viewport 相対のまま(rect をスクロール量で
     ずらす実装だと、スクロール後のタップが外れる)。右下に置く = 全幅要素の中心を覆わない
     (DOM 経路の可視判定は中心点の elementFromPoint。中央に置くと行や本文を不可視にしてしまう) -->
<button id="wv_fixed" style="position: fixed; right: 8px; bottom: 8px;" onclick="setResult('fixed')">固定ボタン</button>
<script>
  function setResult(value) {
    document.getElementById('wv_result').textContent = 'wv_result=' + value;
  }
  var rows = '';
  for (var i = 1; i <= 30; i++) {
    var n = (i < 10 ? '0' : '') + i;
    rows += '<div class="row" id="wv_row_' + n + '">WebView 行 ' + n + '</div>';
  }
  document.getElementById('wv_rows').innerHTML = rows;
</script>
</body>
</html>
`;
