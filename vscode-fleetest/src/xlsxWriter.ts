// xlsxWriter.ts
// 依存ゼロの最小 XLSX(OOXML)ライター(npm 依存を足さない)——
// zip コンテナは node:zlib の deflateRawSync + 自前 CRC32 で組み立てる(zlib.crc32 に頼らない。
// target node18 には無い)。vscode 非依存(resultsExportWorkbook.ts から使われる純粋モジュール)。
//
// 対応範囲: 複数シート・セル値(文字列/数値/数式)・セルスタイル(フォント/塗り/罫線/配置/表示形式、
// キーで重複排除)・列幅・行の高さ・結合セル・ウィンドウ枠の固定・枠線非表示・ズーム・行の
// アウトライン階層・非表示シート。シート名は31文字まで・禁止文字 []:*?/\ を置換・重複は連番で回避。
//
// zip の日時は固定(1980-01-01)。実行のたびにバイト列が変わらないほうがテストしやすく、
// xlsx の実体には意味を持たない値のため。

import { deflateRawSync } from "node:zlib";

// ---- スタイル -----------------------------------------------------------------------------

export type XlsxHorizontalAlign = "left" | "center" | "right";
export type XlsxVerticalAlign = "top" | "center" | "bottom";

export interface XlsxFont {
  readonly name?: string;
  readonly size?: number;
  readonly bold?: boolean;
  /** ARGB(例 "FFFFFFFF")。省略は自動(黒)。 */
  readonly color?: string;
}

export interface XlsxBorderSide {
  readonly style: "thin" | "hair";
}

export interface XlsxBorder {
  readonly left?: XlsxBorderSide;
  readonly right?: XlsxBorderSide;
  readonly top?: XlsxBorderSide;
  readonly bottom?: XlsxBorderSide;
}

export interface XlsxAlignment {
  readonly horizontal?: XlsxHorizontalAlign;
  readonly vertical?: XlsxVerticalAlign;
  readonly wrapText?: boolean;
}

export interface XlsxCellStyle {
  readonly font?: XlsxFont;
  /** 単色塗りつぶしの ARGB。省略は塗りなし。 */
  readonly fillArgb?: string;
  readonly border?: XlsxBorder;
  readonly alignment?: XlsxAlignment;
  /** 表示形式コード(例 "0_ ")。省略は General。**同じコードでも呼ぶたびに新しい numFmtId を
   *  払い出さない** —— コード文字列そのものをキーに dedupe する(registerNumFmt)。 */
  readonly numFmt?: string;
}

export type XlsxCellValue =
  | { readonly kind: "string"; readonly text: string }
  | { readonly kind: "number"; readonly value: number }
  /** 数式。Excel は fullCalcOnLoad(workbook.xml)で開いた時点に再計算するが、Quick Look・Numbers 等は
   *  再計算せず <v> をそのまま出す(無いと空欄)ので、分かっているなら cachedNumber を渡す。 */
  | { readonly kind: "formula"; readonly formula: string; readonly cachedNumber?: number };

interface SheetCell {
  readonly value?: XlsxCellValue;
  readonly styleId?: number;
}

interface SheetRowMeta {
  height?: number;
  outlineLevel?: number;
}

export interface XlsxPane {
  readonly xSplit: number;
  readonly ySplit: number;
  readonly topLeftCell: string;
}

export interface XlsxSheetOptions {
  readonly name: string;
  readonly hidden?: boolean;
  /** 既定 true(枠線あり)。false でグリッド非表示。 */
  readonly showGridLines?: boolean;
  readonly zoomScale?: number;
  readonly freezePane?: XlsxPane;
}

/** 列インデックス(1始まり)→'A'/'B'/…/'AA' の base26(桁なし0の擬似26進)。 */
function colLetters(col: number): string {
  let n = col;
  let s = "";
  while (n > 0) {
    const rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

export function cellRef(row: number, col: number): string {
  return `${colLetters(col)}${row}`;
}

/** "A1:R30" → "$A$1:$R$30"(_xlnm._FilterDatabase の絶対参照形)。 */
function absoluteRange(ref: string): string {
  return ref.replace(/([A-Z]+)(\d+)/g, "$$$1$$$2");
}

// XML 1.0 で許されない制御文字(タブ/改行/復帰は残す)。
const XML_ILLEGAL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g;

function escapeXmlText(text: string): string {
  return text
    .replace(XML_ILLEGAL, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeXmlAttr(text: string): string {
  return escapeXmlText(text).replace(/"/g, "&quot;");
}

/** シート名の正規化(31文字上限・禁止文字 []:*?/\ を "_" へ置換・空は "Sheet"・既出名は連番で回避)。 */
function sanitizeSheetName(rawName: string, used: ReadonlySet<string>): string {
  let name = rawName.replace(/[[\]:*?/\\]/g, "_");
  if (name === "") {
    name = "Sheet";
  }
  name = name.slice(0, 31);
  if (!used.has(name)) {
    return name;
  }
  for (let suffix = 2; suffix < 1000; suffix++) {
    const tail = `_${suffix}`;
    const candidate = name.slice(0, 31 - tail.length) + tail;
    if (!used.has(candidate)) {
      return candidate;
    }
  }
  throw new Error(`sanitizeSheetName: cannot dedupe within 31 characters (${rawName})`);
}

export class XlsxSheet {
  readonly name: string;
  readonly hidden: boolean;
  readonly showGridLines: boolean;
  readonly zoomScale: number | undefined;
  readonly freezePane: XlsxPane | undefined;
  readonly rows = new Map<number, Map<number, SheetCell>>();
  readonly rowMeta = new Map<number, SheetRowMeta>();
  readonly columnWidths = new Map<number, number>();
  readonly merges: string[] = [];
  autoFilterRef: string | undefined;
  private maxCol = 0;
  private maxRow = 0;

  constructor(name: string, options: Omit<XlsxSheetOptions, "name">) {
    this.name = name;
    this.hidden = options.hidden ?? false;
    this.showGridLines = options.showGridLines ?? true;
    this.zoomScale = options.zoomScale;
    this.freezePane = options.freezePane;
  }

  private touch(row: number, col: number): void {
    if (row > this.maxRow) this.maxRow = row;
    if (col > this.maxCol) this.maxCol = col;
  }

  setCell(row: number, col: number, value: XlsxCellValue, styleId?: number): void {
    this.touch(row, col);
    let rowMap = this.rows.get(row);
    if (!rowMap) {
      rowMap = new Map();
      this.rows.set(row, rowMap);
    }
    rowMap.set(col, { value, styleId });
  }

  /** 値の無い(空)セルにスタイルだけ置く(罫線・塗りを空セルにも掛けたいとき)。 */
  setStyleOnly(row: number, col: number, styleId: number): void {
    this.touch(row, col);
    let rowMap = this.rows.get(row);
    if (!rowMap) {
      rowMap = new Map();
      this.rows.set(row, rowMap);
    }
    if (!rowMap.has(col)) {
      rowMap.set(col, { styleId });
    }
  }

  setString(row: number, col: number, text: string, styleId?: number): void {
    this.setCell(row, col, { kind: "string", text }, styleId);
  }

  setNumber(row: number, col: number, value: number, styleId?: number): void {
    this.setCell(row, col, { kind: "number", value }, styleId);
  }

  setFormula(row: number, col: number, formula: string, styleId?: number, cachedNumber?: number): void {
    this.setCell(row, col, { kind: "formula", formula, cachedNumber }, styleId);
  }

  setRowHeight(row: number, height: number): void {
    const meta = this.rowMeta.get(row) ?? {};
    meta.height = height;
    this.rowMeta.set(row, meta);
    if (row > this.maxRow) this.maxRow = row;
  }

  setRowOutlineLevel(row: number, level: number): void {
    const meta = this.rowMeta.get(row) ?? {};
    meta.outlineLevel = level;
    this.rowMeta.set(row, meta);
    if (row > this.maxRow) this.maxRow = row;
  }

  setColumnWidth(col: number, width: number): void {
    this.columnWidths.set(col, width);
    if (col > this.maxCol) this.maxCol = col;
  }

  mergeCells(range: string): void {
    this.merges.push(range);
  }

  setAutoFilter(ref: string): void {
    this.autoFilterRef = ref;
  }

  dimensionRef(): string {
    if (this.maxRow === 0 || this.maxCol === 0) {
      return "A1";
    }
    return `A1:${cellRef(this.maxRow, this.maxCol)}`;
  }
}

// ---- スタイル・レジストリ(重複排除) --------------------------------------------------------

type RegisteredFont = XlsxFont;

function fontKey(f: XlsxFont): string {
  return JSON.stringify([f.name ?? "", f.size ?? 0, !!f.bold, f.color ?? ""]);
}

function borderKey(b: XlsxBorder): string {
  const side = (s?: XlsxBorderSide) => s?.style ?? "";
  return JSON.stringify([side(b.left), side(b.right), side(b.top), side(b.bottom)]);
}

class StyleRegistry {
  private readonly fonts: RegisteredFont[] = [{}]; // index0 = 既定フォント
  private readonly fontIndex = new Map<string, number>([[fontKey({}), 0]]);
  // fills[0]="none" fills[1]="gray125" は OOXML の慣例上の予約(Excel/LibreOffice が前提にする)。
  private readonly fills: (string | null)[] = [null, null];
  private readonly fillIndex = new Map<string, number>();
  private readonly borders: XlsxBorder[] = [{}]; // index0 = 罫線なし
  private readonly borderIndex = new Map<string, number>([[borderKey({}), 0]]);
  private readonly numFmts: string[] = [];
  private readonly numFmtIndex = new Map<string, number>();
  private readonly xfs: { fontId: number; fillId: number; borderId: number; numFmtId: number; alignment?: XlsxAlignment }[] = [
    { fontId: 0, fillId: 0, borderId: 0, numFmtId: 0 },
  ];
  private readonly xfIndex = new Map<string, number>();

  private registerFont(font: XlsxFont | undefined): number {
    const f = font ?? {};
    const key = fontKey(f);
    const existing = this.fontIndex.get(key);
    if (existing !== undefined) return existing;
    const id = this.fonts.length;
    this.fonts.push(f);
    this.fontIndex.set(key, id);
    return id;
  }

  private registerFill(argb: string | undefined): number {
    if (argb === undefined) return 0;
    const existing = this.fillIndex.get(argb);
    if (existing !== undefined) return existing;
    const id = this.fills.length;
    this.fills.push(argb);
    this.fillIndex.set(argb, id);
    return id;
  }

  private registerBorder(border: XlsxBorder | undefined): number {
    const b = border ?? {};
    const key = borderKey(b);
    const existing = this.borderIndex.get(key);
    if (existing !== undefined) return existing;
    const id = this.borders.length;
    this.borders.push(b);
    this.borderIndex.set(key, id);
    return id;
  }

  private registerNumFmt(code: string | undefined): number {
    if (code === undefined) return 0; // General
    const existing = this.numFmtIndex.get(code);
    if (existing !== undefined) return existing;
    // カスタム numFmt は 164 以降(0〜163 は組み込み予約域。既存 ID との衝突を避けるため常にここから払い出す)。
    const id = 164 + this.numFmts.length;
    this.numFmts.push(code);
    this.numFmtIndex.set(code, id);
    return id;
  }

  /** スタイルを登録し、セルの s= に使う xf インデックスを返す(重複は同じ id を返す)。 */
  registerStyle(style: XlsxCellStyle): number {
    const fontId = this.registerFont(style.font);
    const fillId = this.registerFill(style.fillArgb);
    const borderId = this.registerBorder(style.border);
    const numFmtId = this.registerNumFmt(style.numFmt);
    const key = JSON.stringify([fontId, fillId, borderId, numFmtId, style.alignment ?? null]);
    const existing = this.xfIndex.get(key);
    if (existing !== undefined) return existing;
    const id = this.xfs.length;
    this.xfs.push({ fontId, fillId, borderId, numFmtId, alignment: style.alignment });
    this.xfIndex.set(key, id);
    return id;
  }

  toXml(): string {
    const numFmtsXml =
      this.numFmts.length === 0
        ? ""
        : `<numFmts count="${this.numFmts.length}">${this.numFmts
            .map((code, i) => `<numFmt numFmtId="${164 + i}" formatCode="${escapeXmlAttr(code)}"/>`)
            .join("")}</numFmts>`;
    const fontsXml = `<fonts count="${this.fonts.length}">${this.fonts
      .map((f) => {
        const parts: string[] = [];
        if (f.bold) parts.push("<b/>");
        parts.push(`<sz val="${f.size ?? 11}"/>`);
        if (f.color) parts.push(`<color rgb="${escapeXmlAttr(f.color)}"/>`);
        parts.push(`<name val="${escapeXmlAttr(f.name ?? "Calibri")}"/>`);
        return `<font>${parts.join("")}</font>`;
      })
      .join("")}</fonts>`;
    const fillsXml = `<fills count="${this.fills.length}">${this.fills
      .map((argb, i) => {
        if (i === 0) return `<fill><patternFill patternType="none"/></fill>`;
        if (i === 1) return `<fill><patternFill patternType="gray125"/></fill>`;
        return `<fill><patternFill patternType="solid"><fgColor rgb="${escapeXmlAttr(
          argb ?? "FFFFFFFF",
        )}"/><bgColor indexed="64"/></patternFill></fill>`;
      })
      .join("")}</fills>`;
    const borderSideXml = (tag: string, side: XlsxBorderSide | undefined) =>
      side ? `<${tag} style="${side.style}"><color rgb="FF000000"/></${tag}>` : `<${tag}/>`;
    const bordersXml = `<borders count="${this.borders.length}">${this.borders
      .map(
        (b) =>
          `<border>${borderSideXml("left", b.left)}${borderSideXml("right", b.right)}${borderSideXml(
            "top",
            b.top,
          )}${borderSideXml("bottom", b.bottom)}<diagonal/></border>`,
      )
      .join("")}</borders>`;
    const cellXfsXml = `<cellXfs count="${this.xfs.length}">${this.xfs
      .map((xf) => {
        const attrs = [
          `numFmtId="${xf.numFmtId}"`,
          `fontId="${xf.fontId}"`,
          `fillId="${xf.fillId}"`,
          `borderId="${xf.borderId}"`,
          `xfId="0"`,
        ];
        if (xf.numFmtId !== 0) attrs.push('applyNumberFormat="1"');
        if (xf.fontId !== 0) attrs.push('applyFont="1"');
        if (xf.fillId !== 0) attrs.push('applyFill="1"');
        if (xf.borderId !== 0) attrs.push('applyBorder="1"');
        const a = xf.alignment;
        if (a) {
          attrs.push('applyAlignment="1"');
          const alignAttrs = [
            a.horizontal ? `horizontal="${a.horizontal}"` : "",
            a.vertical ? `vertical="${a.vertical}"` : "",
            a.wrapText ? 'wrapText="1"' : "",
          ]
            .filter((s) => s !== "")
            .join(" ");
          return `<xf ${attrs.join(" ")}><alignment ${alignAttrs}/></xf>`;
        }
        return `<xf ${attrs.join(" ")}/>`;
      })
      .join("")}</cellXfs>`;
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
      `${numFmtsXml}${fontsXml}${fillsXml}${bordersXml}` +
      `<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>` +
      `${cellXfsXml}` +
      `<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>` +
      `</styleSheet>`
    );
  }
}

// ---- 共有文字列 ---------------------------------------------------------------------------

class SharedStrings {
  private readonly strings: string[] = [];
  private readonly index = new Map<string, number>();
  private total = 0;

  register(text: string): number {
    this.total++;
    const existing = this.index.get(text);
    if (existing !== undefined) return existing;
    const id = this.strings.length;
    this.strings.push(text);
    this.index.set(text, id);
    return id;
  }

  toXml(): string {
    const items = this.strings
      .map((s) => `<si><t xml:space="preserve">${escapeXmlText(s)}</t></si>`)
      .join("");
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${this.total}" uniqueCount="${this.strings.length}">` +
      `${items}</sst>`
    );
  }
}

// ---- ワークブック --------------------------------------------------------------------------

export class XlsxWorkbook {
  private readonly styles = new StyleRegistry();
  private readonly sharedStrings = new SharedStrings();
  private readonly sheets: XlsxSheet[] = [];
  private readonly usedNames = new Set<string>();

  registerStyle(style: XlsxCellStyle): number {
    return this.styles.registerStyle(style);
  }

  addSheet(options: XlsxSheetOptions): XlsxSheet {
    const name = sanitizeSheetName(options.name, this.usedNames);
    this.usedNames.add(name);
    const sheet = new XlsxSheet(name, options);
    this.sheets.push(sheet);
    return sheet;
  }

  private sheetXml(sheet: XlsxSheet): string {
    // outlineLevelRow が無いと Excel は行のグループ化の記号(左端の +/-)を出さない
    const maxOutline = Math.max(0, ...[...sheet.rowMeta.values()].map((m) => m.outlineLevel ?? 0));
    const hasOutline = maxOutline > 0;
    const sheetPr = hasOutline ? `<sheetPr><outlinePr summaryBelow="0" summaryRight="0"/></sheetPr>` : "";
    const viewAttrs = [
      sheet.showGridLines ? "" : 'showGridLines="0"',
      sheet.zoomScale !== undefined ? `zoomScale="${sheet.zoomScale}"` : "",
      'workbookViewId="0"',
    ]
      .filter((s) => s !== "")
      .join(" ");
    let paneXml = "";
    if (sheet.freezePane) {
      const { xSplit, ySplit, topLeftCell } = sheet.freezePane;
      // **分割していない向きのペインは存在しない** —— xSplit=0 なのに bottomRight と書くと Excel は
      // 「sheetN.xml パーツ内のビュー」を修復する(修復の確認ダイアログが出る)
      const activePane = xSplit > 0 ? (ySplit > 0 ? "bottomRight" : "topRight") : "bottomLeft";
      const splitAttrs = [xSplit > 0 ? `xSplit="${xSplit}"` : "", ySplit > 0 ? `ySplit="${ySplit}"` : ""]
        .filter((a) => a !== "")
        .join(" ");
      paneXml =
        `<pane ${splitAttrs} topLeftCell="${topLeftCell}" activePane="${activePane}" state="frozen"/>` +
        `<selection pane="${activePane}" activeCell="${topLeftCell}" sqref="${topLeftCell}"/>`;
    }
    const sheetViews = `<sheetViews><sheetView ${viewAttrs}>${paneXml}</sheetView></sheetViews>`;

    const colsXml =
      sheet.columnWidths.size === 0
        ? ""
        : `<cols>${[...sheet.columnWidths.entries()]
            .sort((a, b) => a[0] - b[0])
            .map(([col, width]) => `<col min="${col}" max="${col}" width="${width}" customWidth="1"/>`)
            .join("")}</cols>`;

    const rowIndices = new Set<number>([...sheet.rows.keys(), ...sheet.rowMeta.keys()]);
    const sortedRows = [...rowIndices].sort((a, b) => a - b);
    const rowsXml = sortedRows
      .map((rowIdx) => {
        const meta = sheet.rowMeta.get(rowIdx);
        const cellMap = sheet.rows.get(rowIdx);
        const rowAttrs = [
          `r="${rowIdx}"`,
          meta?.height !== undefined ? `ht="${meta.height}" customHeight="1"` : "",
          meta?.outlineLevel ? `outlineLevel="${meta.outlineLevel}"` : "",
        ]
          .filter((s) => s !== "")
          .join(" ");
        const cellsXml = cellMap
          ? [...cellMap.entries()]
              .sort((a, b) => a[0] - b[0])
              .map(([colIdx, cell]) => this.cellXml(rowIdx, colIdx, cell))
              .join("")
          : "";
        return `<row ${rowAttrs}>${cellsXml}</row>`;
      })
      .join("");

    const mergeXml =
      sheet.merges.length === 0
        ? ""
        : `<mergeCells count="${sheet.merges.length}">${sheet.merges
            .map((range) => `<mergeCell ref="${escapeXmlAttr(range)}"/>`)
            .join("")}</mergeCells>`;
    const autoFilterXml = sheet.autoFilterRef ? `<autoFilter ref="${escapeXmlAttr(sheet.autoFilterRef)}"/>` : "";
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
      `${sheetPr}<dimension ref="${sheet.dimensionRef()}"/>${sheetViews}` +
      `<sheetFormatPr defaultRowHeight="15"${hasOutline ? ` outlineLevelRow="${maxOutline}"` : ""}/>${colsXml}` +
      // CT_Worksheet の並び: sheetData → autoFilter → mergeCells(ECMA-376 準拠。
      // 順序違反は Excel が「破損」として開けない。xlsxWriter.test.mjs のスキーマ順テスト参照)。
      `<sheetData>${rowsXml}</sheetData>${autoFilterXml}${mergeXml}` +
      `</worksheet>`
    );
  }

  private cellXml(row: number, col: number, cell: SheetCell): string {
    const ref = cellRef(row, col);
    const s = cell.styleId !== undefined ? ` s="${cell.styleId}"` : "";
    if (!cell.value) {
      return `<c r="${ref}"${s}/>`;
    }
    if (cell.value.kind === "string") {
      const idx = this.sharedStrings.register(cell.value.text);
      return `<c r="${ref}"${s} t="s"><v>${idx}</v></c>`;
    }
    if (cell.value.kind === "number") {
      return `<c r="${ref}"${s}><v>${cell.value.value}</v></c>`;
    }
    const cached = cell.value.cachedNumber !== undefined ? `<v>${cell.value.cachedNumber}</v>` : "";
    return `<c r="${ref}"${s}><f>${escapeXmlText(cell.value.formula)}</f>${cached}</c>`;
  }

  private workbookXml(): string {
    const sheetsXml = this.sheets
      .map((sheet, i) => {
        const attrs = [
          `name="${escapeXmlAttr(sheet.name)}"`,
          `sheetId="${i + 1}"`,
          sheet.hidden ? 'state="hidden"' : "",
          `r:id="rId${i + 1}"`,
        ]
          .filter((s) => s !== "")
          .join(" ");
        return `<sheet ${attrs}/>`;
      })
      .join("");
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
      // **要素順はスキーマ固定**(bookViews → sheets → … → calcPr)。calcPr を sheets より前に置くと
      // Excel は「破損」として開けず修復もできない(Quick Look・Numbers は黙って開くので気付けない)。
      // sheetView の workbookViewId="0" が指す先として bookViews も要る
      `<bookViews><workbookView/></bookViews>` +
      `<sheets>${sheetsXml}</sheets>` +
      `${this.definedNamesXml()}` +
      `<calcPr fullCalcOnLoad="1"/>` +
      `</workbook>`
    );
  }

  /** autoFilter を持つシートぶんの _xlnm._FilterDatabase(Excel がオートフィルタを認識するのに要る)。
   *  無ければ要素ごと省く。 */
  private definedNamesXml(): string {
    const entries = this.sheets
      .map((sheet, i) => {
        if (!sheet.autoFilterRef) return "";
        const quotedName = sheet.name.replace(/'/g, "''");
        const content = `'${quotedName}'!${absoluteRange(sheet.autoFilterRef)}`;
        return `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">${escapeXmlText(content)}</definedName>`;
      })
      .join("");
    return entries === "" ? "" : `<definedNames>${entries}</definedNames>`;
  }

  private workbookRelsXml(): string {
    const sheetRels = this.sheets
      .map(
        (_sheet, i) =>
          `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`,
      )
      .join("");
    const n = this.sheets.length;
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
      `${sheetRels}` +
      `<Relationship Id="rId${n + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
      `<Relationship Id="rId${n + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>` +
      `</Relationships>`
    );
  }

  private contentTypesXml(): string {
    const sheetOverrides = this.sheets
      .map(
        (_sheet, i) =>
          `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`,
      )
      .join("");
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
      `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
      `<Default Extension="xml" ContentType="application/xml"/>` +
      `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
      `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
      `<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>` +
      `${sheetOverrides}` +
      `<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>` +
      `<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>` +
      `</Types>`
    );
  }

  private static readonly ROOT_RELS =
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
    `<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>` +
    `<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>` +
    `</Relationships>`;

  private coreXml(): string {
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ` +
      `xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">` +
      `<dc:creator>fleetest</dc:creator>` +
      `</cp:coreProperties>`
    );
  }

  private appXml(): string {
    return (
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
      `<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ` +
      `xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">` +
      `<Application>fleetest</Application>` +
      `</Properties>`
    );
  }

  /** zip(OOXML パッケージ)へ直列化する。 */
  toBuffer(): Buffer {
    const entries: { path: string; data: Buffer }[] = [];
    const put = (p: string, xml: string) => entries.push({ path: p, data: Buffer.from(xml, "utf8") });
    // **シートの XML を先に作る**(cellXml が文字列セルの内容を共有文字列テーブルへ登録するのは
    // この呼び出しの中。sharedStrings.toXml() をこれより先に呼ぶと空のまま固まる)。
    const sheetXmls = this.sheets.map((sheet) => this.sheetXml(sheet));
    put("[Content_Types].xml", this.contentTypesXml());
    put("_rels/.rels", XlsxWorkbook.ROOT_RELS);
    put("docProps/core.xml", this.coreXml());
    put("docProps/app.xml", this.appXml());
    put("xl/workbook.xml", this.workbookXml());
    put("xl/_rels/workbook.xml.rels", this.workbookRelsXml());
    put("xl/styles.xml", this.styles.toXml());
    put("xl/sharedStrings.xml", this.sharedStrings.toXml());
    sheetXmls.forEach((xml, i) => put(`xl/worksheets/sheet${i + 1}.xml`, xml));
    return buildZip(entries);
  }
}

// ---- zip コンテナ(格納は deflate 固定・日時は 1980-01-01 固定) --------------------------------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf: Buffer): number {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    crc = CRC_TABLE[(crc ^ buf[i]!) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

const DOS_TIME = 0x0000;
const DOS_DATE = 0x0021; // 1980-01-01

function buildZip(entries: readonly { path: string; data: Buffer }[]): Buffer {
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let offset = 0;

  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.path, "utf8");
    const compressed = deflateRawSync(entry.data);
    const crc = crc32(entry.data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0, 6); // flags
    local.writeUInt16LE(8, 8); // method: deflate
    local.writeUInt16LE(DOS_TIME, 10);
    local.writeUInt16LE(DOS_DATE, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(entry.data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28); // extra field length
    localParts.push(local, nameBuf, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4); // version made by
    central.writeUInt16LE(20, 6); // version needed
    central.writeUInt16LE(0, 8); // flags
    central.writeUInt16LE(8, 10); // method
    central.writeUInt16LE(DOS_TIME, 12);
    central.writeUInt16LE(DOS_DATE, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(entry.data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt16LE(0, 30); // extra length
    central.writeUInt16LE(0, 32); // comment length
    central.writeUInt16LE(0, 34); // disk number start
    central.writeUInt16LE(0, 36); // internal attrs
    central.writeUInt32LE(0, 38); // external attrs
    central.writeUInt32LE(offset, 42); // local header offset
    centralParts.push(central, nameBuf);

    offset += local.length + nameBuf.length + compressed.length;
  }

  const centralStart = offset;
  const centralBuf = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4); // disk number
  end.writeUInt16LE(0, 6); // disk with central dir
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBuf.length, 12);
  end.writeUInt32LE(centralStart, 16);
  end.writeUInt16LE(0, 20); // comment length

  return Buffer.concat([...localParts, centralBuf, end]);
}
