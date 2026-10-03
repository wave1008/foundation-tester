// 仮想デバイス名「<機種>(<OS ラベル>)-NN」の組み立て(DOM 非依存)。
// 同期相手: Sources/FTCore/VirtualDeviceNaming.swift。正解表は Tests/Fixtures/VirtualDeviceNaming/cases.json
// (test/deviceNaming.test.mjs と Swift 側のテストが同じ JSON を読む)。片方だけ変えない。

const MAX_SERIAL = 99;

/** "iPhone 17 Pro(iOS 27.0)"。括弧は ASCII・空白なし */
export function baseName(model, osLabel) {
  return model + '(' + osLabel + ')';
}

// `<base>-NN`(NN はちょうど2桁の ASCII 数字)なら NN。それ以外(前方一致だけの別機種・-1・-001)は null
function serialNumber(name, base) {
  const prefix = base + '-';
  if (!name.startsWith(prefix)) {
    return null;
  }
  const suffix = name.slice(prefix.length);
  return /^[0-9]{2}$/.test(suffix) ? Number(suffix) : null;
}

/** existing に無い `<base>-NN` を小さい順に count 個(01〜99。足りなければ count 未満) */
export function nextUnusedNames(base, existing, count) {
  const used = new Set();
  for (const name of existing) {
    const n = serialNumber(name, base);
    if (n !== null) {
      used.add(n);
    }
  }
  const names = [];
  for (let n = 1; n <= MAX_SERIAL && names.length < count; n += 1) {
    if (!used.has(n)) {
      names.push(base + '-' + String(n).padStart(2, '0'));
    }
  }
  return names;
}
