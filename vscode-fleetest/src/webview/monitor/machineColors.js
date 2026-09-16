// machineColors.js
// リモートマシンのバッジ(.badge-remote)の色。**パレットの定義は CLI が持つ**(拡張は定数を
// 持たない。FM 枠の既定値 defaultFMConcurrency と同じ規律)—— remoteConfig の machineColors[]
// (鍵→hex。全て黒字 #1f1f1f が読める淡色という前提。文字色は style.css の .badge-remote 固定のまま)
// と hosts[].color(machine→鍵)から作り直す。
//
// 可変状態はこのモジュールに置く(書き込み箇所と同じモジュールに置く規律)。バッジを描く
// 5箇所(deviceTiles.js/laneLog.js/runProfilesTab.js/runProfileDevicesTab.js/recordingsTab.js)は
// paintMachineBadge を呼ぶだけで、パレットの中身を知らない。設定タブのスウォッチ選択は
// machineColorPalette()/hexForColorKey() で読み取り専用に参照する。

let palette = [];            // [{key, color}, ...] 表示順 = 配列順。古い CLI からは空のまま
let paletteByKey = new Map(); // key -> color(hex)
let hexByMachine = new Map(); // machine -> color(hex)。鍵が不明(パレット未受信・未知の鍵)なら持たない

/** remoteConfig 受信のたびに呼ぶ。パレットと machine→色の対応を作り直し、既に描かれている
 *  バッジ(data-machine を持つもの)を塗り直す。machineColors が配列でなければパレットは空
 *  (色機能を黙って無効にする)。 */
export function applyMachineColors(message) {
  const colors = Array.isArray(message.machineColors) ? message.machineColors : [];
  palette = colors.filter(
    (c) => c && typeof c.key === 'string' && c.key !== '' && typeof c.color === 'string' && c.color !== '',
  );
  paletteByKey = new Map(palette.map((c) => [c.key, c.color]));

  hexByMachine = new Map();
  const hosts = Array.isArray(message.hosts) ? message.hosts : [];
  for (const host of hosts) {
    if (typeof host.machine !== 'string' || host.machine === '' || typeof host.color !== 'string') {
      continue;
    }
    const hex = paletteByKey.get(host.color);
    if (hex) {
      hexByMachine.set(host.machine, hex);
    }
  }
  repaintMachineBadges();
}

/** バッジ1つを machine の色で塗る。machine が無ければ**既定へ戻す**(dataset.machine を消し、
 *  背景色の上書きも外す = CSS の .badge-remote の既定グレーに戻る)。バッジのテキストを立てる/
 *  非表示にする箇所は、その直後にこれも呼ぶこと(呼び忘れると色が古いマシン名のまま残る)。 */
export function paintMachineBadge(el, machine) {
  if (!machine) {
    delete el.dataset.machine;
    el.style.removeProperty('background-color');
    return;
  }
  el.dataset.machine = machine;
  const hex = hexByMachine.get(machine);
  if (hex) {
    el.style.backgroundColor = hex;
  } else {
    el.style.removeProperty('background-color');
  }
}

/** config が後から届いたとき・パレットが変わったときに、既存のバッジへ反映する。 */
export function repaintMachineBadges() {
  for (const el of document.querySelectorAll('.badge-remote[data-machine]')) {
    paintMachineBadge(el, el.dataset.machine);
  }
}

/** 設定タブのスウォッチ用パレット(コピーを返す。呼び手が変更しても内部状態には影響しない)。 */
export function machineColorPalette() {
  return palette.slice();
}

/** 設定タブのスウォッチ用: 鍵から hex を引く。未受信・未知の鍵なら undefined。 */
export function hexForColorKey(key) {
  return paletteByKey.get(key);
}
