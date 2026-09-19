// xlsxWriter.test.mjs
// xlsxWriter.ts(依存ゼロの最小 XLSX ライター)のユニットテスト。生成した zip を自前でパースし
// (local file header → central directory の offset/size を読み、zlib.inflateRawSync で展開)、
// CRC32 が一致すること・必要な OOXML パーツが揃っていること・エスケープ/結合セル/固定枠の XML が
// 出ていることを確認する。npm 依存は追加しない方針を検証コードでも守る(zip パーサも自前)。

import assert from "node:assert/strict";
import { test } from "node:test";
import zlib from "node:zlib";
import { XlsxWorkbook } from "../src/xlsxWriter";

// CRC32(標準多項式 0xEDB88320)。production 側(xlsxWriter.ts)の実装とは独立に書く
// (同じ表を共有すると「production が誤っていてもテストが道連れで緑になる」を防げない)。
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();
function ownCrc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) crc = CRC_TABLE[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
const crc32 = typeof zlib.crc32 === "function" ? (buf) => zlib.crc32(buf) : ownCrc32;

/** production の zip(コメント無し・非 zip64)を読み、{name: 展開済みテキスト} の Map を返す。
 * 各エントリの CRC32/展開後サイズを central directory の値と突き合わせてから採用する。 */
function readZip(buffer) {
  const eocd = buffer.subarray(buffer.length - 22);
  assert.equal(eocd.readUInt32LE(0), 0x06054b50, "End Of Central Directory signature");
  const totalEntries = eocd.readUInt16LE(10);
  const centralOffset = eocd.readUInt32LE(16);

  const files = new Map();
  let offset = centralOffset;
  for (let i = 0; i < totalEntries; i++) {
    assert.equal(buffer.readUInt32LE(offset), 0x02014b50, `central directory signature (entry ${i})`);
    const crc = buffer.readUInt32LE(offset + 16);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const uncompressedSize = buffer.readUInt32LE(offset + 24);
    const nameLen = buffer.readUInt16LE(offset + 28);
    const extraLen = buffer.readUInt16LE(offset + 30);
    const commentLen = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLen).toString("utf8");

    assert.equal(buffer.readUInt32LE(localOffset), 0x04034b50, `local file header signature (${name})`);
    const localNameLen = buffer.readUInt16LE(localOffset + 26);
    const localExtraLen = buffer.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLen + localExtraLen;
    const compressed = buffer.subarray(dataStart, dataStart + compressedSize);
    const data = zlib.inflateRawSync(compressed);
    assert.equal(data.length, uncompressedSize, `uncompressed size (${name})`);
    assert.equal(crc32(data), crc, `CRC32 (${name})`);
    files.set(name, data.toString("utf8"));

    offset += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

test("最小構成のワークブックが有効な OOXML パッケージの必須パーツを持つ", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({ name: "シート1" });
  sheet.setString(1, 1, "hello");
  const buffer = workbook.toBuffer();
  const files = readZip(buffer);

  for (const part of [
    "[Content_Types].xml",
    "_rels/.rels",
    "xl/workbook.xml",
    "xl/_rels/workbook.xml.rels",
    "xl/styles.xml",
    "xl/sharedStrings.xml",
    "xl/worksheets/sheet1.xml",
  ]) {
    assert.ok(files.has(part), `missing part: ${part}`);
  }
  assert.match(files.get("xl/workbook.xml"), /<sheet name="シート1"/);
  assert.match(files.get("xl/worksheets/sheet1.xml"), /<c r="A1"[^>]*t="s"><v>0<\/v><\/c>/);
});

test("文字列セルは XML エスケープされ、往復で元の文字列に戻る(改行込み)", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({ name: "Sheet1" });
  const text = "a<b&\n";
  sheet.setString(1, 1, text);
  const files = readZip(workbook.toBuffer());
  const sst = files.get("xl/sharedStrings.xml");
  assert.match(sst, /<t xml:space="preserve">a&lt;b&amp;\n<\/t>/, "エスケープ済みかつ改行を保持");

  // 素朴な逆変換(&lt;→<, &amp;→&, その他はそのまま)で元の文字列に戻ることを確認する。
  const inner = sst.match(/<t xml:space="preserve">([\s\S]*?)<\/t>/)[1];
  const roundTripped = inner.replace(/&lt;/g, "<").replace(/&amp;/g, "&");
  assert.equal(roundTripped, text);
});

test("結合セルは mergeCells/mergeCell として出力される", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({ name: "Sheet1" });
  sheet.setString(1, 1, "project");
  sheet.mergeCells("A1:C1");
  const files = readZip(workbook.toBuffer());
  assert.match(files.get("xl/worksheets/sheet1.xml"), /<mergeCells count="1"><mergeCell ref="A1:C1"\/><\/mergeCells>/);
});

test("固定枠(freezePane)は pane/selection として出力され、showGridLines=0/zoomScale も反映される", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({
    name: "Sheet1",
    showGridLines: false,
    zoomScale: 110,
    freezePane: { xSplit: 4, ySplit: 9, topLeftCell: "E10" },
  });
  sheet.setString(1, 1, "x");
  const xml = readZip(workbook.toBuffer()).get("xl/worksheets/sheet1.xml");
  assert.match(xml, /showGridLines="0"/);
  assert.match(xml, /zoomScale="110"/);
  assert.match(xml, /<pane xSplit="4" ySplit="9" topLeftCell="E10" activePane="bottomRight" state="frozen"\/>/);
  assert.match(xml, /<selection pane="bottomRight"/);
  assert.match(xml, /<selection pane="bottomRight" activeCell="E10" sqref="E10"\/>/);
});

test("複数シート・非表示シート・シート名の重複回避(31文字上限・禁止文字の置換)", () => {
  const workbook = new XlsxWorkbook();
  workbook.addSheet({ name: "A".repeat(40) });
  const dup1 = workbook.addSheet({ name: "重複" });
  const dup2 = workbook.addSheet({ name: "重複" });
  const hidden = workbook.addSheet({ name: "hide:me?/x*[y]", hidden: true });
  const files = readZip(workbook.toBuffer());

  assert.equal(dup1.name.length <= 31, true);
  assert.notEqual(dup1.name, dup2.name, "同名シートは連番等で回避される");
  assert.equal(/[[\]:*?/\\]/.test(hidden.name), false, "禁止文字は置換される");

  const wbXml = files.get("xl/workbook.xml");
  assert.match(wbXml, new RegExp(`name="${hidden.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"[^>]*state="hidden"`));
  for (let i = 1; i <= 4; i++) {
    assert.ok(files.has(`xl/worksheets/sheet${i}.xml`), `sheet${i}.xml`);
  }
});

test("数値・数式セルはそのまま(t 属性なし)で出力され、数式は <f> を持つ", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({ name: "Sheet1" });
  sheet.setNumber(1, 1, 42);
  sheet.setFormula(2, 1, "ROW()-9");
  // 計算済みの値は <v> で添える(再計算しないビューア = Quick Look・Numbers 向け)
  sheet.setFormula(12, 1, "ROW()-9", undefined, 3);
  const xml = readZip(workbook.toBuffer()).get("xl/worksheets/sheet1.xml");
  assert.match(xml, /<c r="A1"><v>42<\/v><\/c>/);
  assert.match(xml, /<c r="A2"[^>]*><f>ROW\(\)-9<\/f><\/c>/);
  assert.match(xml, /<c r="A12"[^>]*><f>ROW\(\)-9<\/f><v>3<\/v><\/c>/);
});

test("スタイルはキーで重複排除される(同じ内容は同じ id)", () => {
  const workbook = new XlsxWorkbook();
  const idA = workbook.registerStyle({ font: { name: "Meiryo UI", size: 9, bold: true }, fillArgb: "FF92D050" });
  const idB = workbook.registerStyle({ font: { name: "Meiryo UI", size: 9, bold: true }, fillArgb: "FF92D050" });
  const idC = workbook.registerStyle({ font: { name: "Meiryo UI", size: 9, bold: false }, fillArgb: "FF92D050" });
  assert.equal(idA, idB);
  assert.notEqual(idA, idC);
});

test("行の高さ・列幅・行のアウトライン階層が反映される", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({ name: "Sheet1" });
  sheet.setString(1, 1, "x");
  sheet.setRowHeight(1, 22);
  sheet.setColumnWidth(1, 12.5);
  sheet.setString(2, 1, "y");
  sheet.setRowOutlineLevel(2, 1);
  const xml = readZip(workbook.toBuffer()).get("xl/worksheets/sheet1.xml");
  assert.match(xml, /<row r="1" ht="22" customHeight="1">/);
  assert.match(xml, /<col min="1" max="1" width="12.5" customWidth="1"\/>/);
  assert.match(xml, /<row r="2" outlineLevel="1">/);
  assert.match(xml, /<sheetPr><outlinePr summaryBelow="0" summaryRight="0"\/><\/sheetPr>/);
});

// Excel は最上位要素の順序違反を「破損」として開かない(修復も不可)。Quick Look・Numbers は黙って開くので
// 見た目の確認では捕まらない —— ECMA-376 の xsd:sequence の順序どおりかを直接見る。
function topLevelOrder(xml, root) {
  const body = xml.slice(xml.indexOf(`<${root}`));
  const inner = body.slice(body.indexOf(">") + 1, body.lastIndexOf(`</${root}>`));
  const names = [];
  let depth = 0;
  for (const m of inner.matchAll(/<(\/?)([A-Za-z:]+)[^>]*?(\/?)>/g)) {
    if (m[1] === "/") { depth--; continue; }
    if (depth === 0) names.push(m[2]);
    if (m[3] !== "/") depth++;
  }
  return names;
}

function assertSchemaOrder(names, schemaOrder, label) {
  const positions = names.map((n) => {
    const i = schemaOrder.indexOf(n);
    assert.notEqual(i, -1, `${label}: unexpected element <${n}>`);
    return i;
  });
  for (let i = 1; i < positions.length; i++) {
    assert.ok(positions[i - 1] < positions[i], `${label}: <${names[i - 1]}> must come after <${names[i]}> per schema (got ${names.join(", ")})`);
  }
}

test("workbook/styles/worksheet の最上位要素がスキーマの順序どおり(順序違反は Excel で破損扱い)", () => {
  const workbook = new XlsxWorkbook();
  const sheet = workbook.addSheet({ name: "S", showGridLines: false, zoomScale: 110, freezePane: { xSplit: 4, ySplit: 9, topLeftCell: "E10" } });
  sheet.setString(1, 1, "x", workbook.registerStyle({ numFmt: "0_ ", fillArgb: "FF92D050", alignment: { horizontal: "center" } }));
  sheet.setColumnWidth(1, 5);
  sheet.setRowOutlineLevel(2, 1);
  sheet.mergeCells("A1:C1");
  sheet.setAutoFilter("A1:C1");
  sheet.setHyperlink(3, 1, "リンク", "/tmp/日本語.txt");
  const files = readZip(workbook.toBuffer());
  const wb = topLevelOrder(files.get("xl/workbook.xml"), "workbook");
  assertSchemaOrder(wb, ["fileVersion", "fileSharing", "workbookPr", "workbookProtection", "bookViews", "sheets",
    "functionGroups", "externalReferences", "definedNames", "calcPr"], "workbook.xml");
  assert.ok(wb.includes("bookViews") && wb.includes("sheets") && wb.includes("definedNames") && wb.includes("calcPr"), wb.join(","));
  assertSchemaOrder(topLevelOrder(files.get("xl/styles.xml"), "styleSheet"), ["numFmts", "fonts", "fills", "borders",
    "cellStyleXfs", "cellXfs", "cellStyles", "dxfs", "tableStyles", "colors", "extLst"], "styles.xml");
  const sheet1Order = topLevelOrder(files.get("xl/worksheets/sheet1.xml"), "worksheet");
  assertSchemaOrder(sheet1Order, ["sheetPr", "dimension",
    "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr", "sheetProtection", "protectedRanges",
    "scenarios", "autoFilter", "sortState", "dataConsolidate", "customSheetViews", "mergeCells", "phoneticPr",
    "conditionalFormatting", "dataValidations", "hyperlinks", "printOptions", "pageMargins"], "sheet1.xml");
  assert.ok(sheet1Order.includes("autoFilter") && sheet1Order.includes("mergeCells") && sheet1Order.includes("hyperlinks"),
    sheet1Order.join(","));

  // _xlnm._FilterDatabase(オートフィルタを Excel に認識させるのに要る)。
  assert.match(files.get("xl/workbook.xml"), /<definedName name="_xlnm\._FilterDatabase" localSheetId="0" hidden="1">'S'!\$A\$1:\$C\$1<\/definedName>/);

  // ハイパーリンクは同シートの _rels ファイルに外部 file URL(percent-encoded)として書かれる。
  const rels = files.get("xl/worksheets/_rels/sheet1.xml.rels");
  assert.ok(rels, "sheet1.xml.rels が無い");
  assert.match(rels, /Type="http:\/\/schemas\.openxmlformats\.org\/officeDocument\/2006\/relationships\/hyperlink"/);
  assert.match(rels, /TargetMode="External"/);
  assert.match(rels, /Target="file:\/\/[^"]*%E6[^"]*\.txt"/, rels);
  assert.match(files.get("xl/worksheets/sheet1.xml"), /<hyperlinks><hyperlink ref="A3" r:id="rId1"\/><\/hyperlinks>/);
});

test("下線付きフォントは <u/> を持ち、下線なしと同じキーで重複排除されない", () => {
  const workbook = new XlsxWorkbook();
  const underlined = workbook.registerStyle({ font: { name: "Meiryo UI", color: "FF0563C1", underline: true } });
  const plain = workbook.registerStyle({ font: { name: "Meiryo UI", color: "FF0563C1" } });
  assert.notEqual(underlined, plain);
  const sheet = workbook.addSheet({ name: "Sheet1" });
  sheet.setString(1, 1, "link", underlined);
  const xml = readZip(workbook.toBuffer()).get("xl/styles.xml");
  assert.match(xml, /<font><u\/><sz val="11"\/><color rgb="FF0563C1"\/><name val="Meiryo UI"\/><\/font>/);
});

// 分割していない向きのペインを名乗ると Excel が「パーツ内のビュー」を修復する(確認ダイアログが出る)。
test("固定枠が片方向だけのときは活性ペインをその向きに合わせる(xSplit=0 で bottomRight と書かない)", () => {
  const workbook = new XlsxWorkbook();
  workbook.addSheet({ name: "行だけ", freezePane: { xSplit: 0, ySplit: 1, topLeftCell: "A2" } }).setString(1, 1, "x");
  workbook.addSheet({ name: "列だけ", freezePane: { xSplit: 2, ySplit: 0, topLeftCell: "C1" } }).setString(1, 1, "x");
  const files = readZip(workbook.toBuffer());
  const rowOnly = files.get("xl/worksheets/sheet1.xml");
  assert.match(rowOnly, /<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"\/>/);
  assert.match(rowOnly, /<selection pane="bottomLeft"/);
  assert.doesNotMatch(rowOnly, /xSplit="0"/);
  const colOnly = files.get("xl/worksheets/sheet2.xml");
  assert.match(colOnly, /<pane xSplit="2" topLeftCell="C1" activePane="topRight" state="frozen"\/>/);
  assert.match(colOnly, /<selection pane="topRight"/);
  assert.doesNotMatch(colOnly, /ySplit="0"/);
});
