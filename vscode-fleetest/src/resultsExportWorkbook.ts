// resultsExportWorkbook.ts
// ResultsExportModel(resultsExportModel.ts。locale 非依存の中立データ)を fleetest 向けレイアウトで
// xlsxWriter.ts の呼び出しへ変換する。文言はここで初めて t()(拡張側 i18n。locale は
// fleetest.language)を通して解決する——モデル自体は locale を知らない。

import { t, type MessageKey } from "./i18n";
import type {
  ResultsExportClassSummary,
  ResultsExportFmSettings,
  ResultsExportModel,
  ResultsExportScenarioResult,
} from "./resultsExportModel";
import { type XlsxFont, XlsxSheet, XlsxWorkbook } from "./xlsxWriter";
import type { XlsxBorder } from "./xlsxWriter";

const FONT_NAME = "Meiryo UI";
const HEADER_FILL = "FF1F3864";
const SCENARIO_HEADER_FILL = "FFD9E1F2"; // ステップシートのシナリオ見出し行
const SUCCESS_FILL = "FFC6EFCE";
const FAILURE_FILL = "FFFFC7CE";
const TIMEOUT_FILL = "FFFFEB9C"; // タイムアウト/中断で共用
const SKIP_FILL = "FFE7E6E6"; // スキップ/未実行で共用
const HEAL_FILL = "FFDDEBF7"; // 自己修復/代替で成功で共用

const DATE_TIME_NUMFMT = "yyyy/mm/dd hh:mm:ss";
const DURATION_NUMFMT = "0.0";

/** 概要シートのクラス別テーブルの見出し行(固定レイアウト。freezePane はシート作成時に要るので
 *  データ件数を待たずに決め打つ)。 */
const OVERVIEW_CLASS_HEADER_ROW = 21;

const DATA_BORDER: XlsxBorder = {
  left: { style: "thin" },
  right: { style: "thin" },
  top: { style: "thin" },
  bottom: { style: "thin" },
};

// 開始列(10列目)は "yyyy/mm/dd hh:mm:ss" が切れない幅
const SCENARIOS_COLUMN_WIDTHS: readonly number[] = [
  5, 24, 10, 36, 8, 26, 12, 10, 8, 20, 8, 24, 36, 12, 48, 20,
];
const STEPS_COLUMN_WIDTHS: readonly number[] = [24, 10, 6, 20, 10, 5, 50, 10, 8, 24];

const SCENARIO_RESULT_FILL: Record<ResultsExportScenarioResult, string> = {
  success: SUCCESS_FILL,
  failure: FAILURE_FILL,
  timeout: TIMEOUT_FILL,
  interrupted: TIMEOUT_FILL,
  skipped: SKIP_FILL,
};
const SCENARIO_RESULT_LABEL_KEY: Record<ResultsExportScenarioResult, MessageKey> = {
  success: "resultsExport.result.success",
  failure: "resultsExport.result.failure",
  timeout: "resultsExport.result.timeout",
  interrupted: "resultsExport.result.interrupted",
  skipped: "resultsExport.result.skipped",
};

const STEP_STATUS_FILL: { readonly [status: string]: string } = {
  passed: SUCCESS_FILL,
  passedViaFallback: HEAL_FILL,
  healed: HEAL_FILL,
  failed: FAILURE_FILL,
  skipped: SKIP_FILL,
};
const STEP_STATUS_LABEL_KEY: { readonly [status: string]: MessageKey } = {
  passed: "resultsExport.stepStatus.passed",
  passedViaFallback: "resultsExport.stepStatus.passedViaFallback",
  healed: "resultsExport.stepStatus.healed",
  failed: "resultsExport.stepStatus.failed",
  skipped: "resultsExport.stepStatus.skipped",
};

const SECTION_LABEL_KEY: { readonly [section: string]: MessageKey } = {
  condition: "resultsExport.section.condition",
  action: "resultsExport.section.action",
  expectation: "resultsExport.section.expectation",
  setUp: "resultsExport.section.setUp",
  tearDown: "resultsExport.section.tearDown",
};

function baseFont(overrides: Partial<XlsxFont> = {}): XlsxFont {
  return { name: FONT_NAME, ...overrides };
}

function platformLabel(platform: string | null): string | null {
  if (platform === "ios") return "iOS";
  if (platform === "android") return "Android";
  return null;
}

function scenarioResultLabel(result: ResultsExportScenarioResult): string {
  return t(SCENARIO_RESULT_LABEL_KEY[result]);
}

function stepStatusLabel(status: string): string {
  const key = STEP_STATUS_LABEL_KEY[status];
  return key ? t(key) : status;
}

function sectionLabel(section: string | null): string {
  if (section === null) return "";
  const key = SECTION_LABEL_KEY[section];
  return key ? t(key) : section;
}

/** Excel のシリアル日付(1900 日付システム)。ローカル時刻の壁時計をそのまま UTC として書き込む
 *  慣例(serial = localEpochMs/86400000 + 25569)。不正な ISO 文字列は null。 */
function excelDateSerial(iso: string): number | null {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return null;
  const d = new Date(ms);
  const localMs = ms - d.getTimezoneOffset() * 60000;
  return localMs / 86400000 + 25569;
}

function fmSettingsText(fm: ResultsExportFmSettings | null): string {
  if (fm === null) return "";
  const parts: readonly [boolean | null, MessageKey][] = [
    [fm.heal, "resultsExport.fm.heal"],
    [fm.textVisualCheck, "resultsExport.fm.textVisualCheck"],
    [fm.ocrTextVisualCheck, "resultsExport.fm.ocrTextVisualCheck"],
    [fm.screenLooksLike, "resultsExport.fm.screenLooksLike"],
  ];
  return parts
    .filter((p): p is [boolean, MessageKey] => p[0] !== null)
    .map(([on, key]) => `${t(key)}=${on ? t("resultsExport.fm.on") : t("resultsExport.fm.off")}`)
    .join(", ");
}

export function buildResultsExportWorkbook(model: ResultsExportModel): XlsxWorkbook {
  const workbook = new XlsxWorkbook();

  const overviewSheet = workbook.addSheet({
    name: t("resultsExport.sheet.overview"),
    showGridLines: false,
    freezePane: { xSplit: 0, ySplit: OVERVIEW_CLASS_HEADER_ROW, topLeftCell: `A${OVERVIEW_CLASS_HEADER_ROW + 1}` },
  });
  renderOverviewSheet(workbook, overviewSheet, model);

  const scenariosSheet = workbook.addSheet({
    name: t("resultsExport.sheet.scenarios"),
    showGridLines: false,
    freezePane: { xSplit: 3, ySplit: 1, topLeftCell: "D2" },
  });
  renderScenariosSheet(workbook, scenariosSheet, model);

  const stepsSheet = workbook.addSheet({
    name: t("resultsExport.sheet.steps"),
    showGridLines: false,
    freezePane: { xSplit: 2, ySplit: 1, topLeftCell: "C2" },
  });
  renderStepsSheet(workbook, stepsSheet, model);

  return workbook;
}

function renderOverviewSheet(workbook: XlsxWorkbook, sheet: XlsxSheet, model: ResultsExportModel): void {
  const { overview, classes } = model;
  // A = ラベル/クラス名、B = 値(日付の書式と設定の一覧が入るので広く取る)
  sheet.setColumnWidth(1, 26);
  sheet.setColumnWidth(2, 46);
  for (let c = 3; c <= 7; c++) sheet.setColumnWidth(c, 14);

  const titleStyle = workbook.registerStyle({ font: baseFont({ bold: true, size: 14 }) });
  sheet.setString(1, 1, t("resultsExport.overview.title", { project: model.project }), titleStyle);

  const labelStyle = workbook.registerStyle({ font: baseFont({ bold: true }) });
  const valueStyle = workbook.registerStyle({ font: baseFont() });
  const dateStyle = workbook.registerStyle({ font: baseFont(), numFmt: DATE_TIME_NUMFMT });
  const durationStyle = workbook.registerStyle({ font: baseFont(), numFmt: DURATION_NUMFMT });

  const setLabel = (row: number, key: MessageKey) => sheet.setString(row, 1, t(key), labelStyle);
  setLabel(3, "resultsExport.overview.project");
  sheet.setString(3, 2, overview.project, valueStyle);
  setLabel(4, "resultsExport.overview.session");
  sheet.setString(4, 2, overview.runIDs.join(", "), valueStyle);
  setLabel(5, "resultsExport.overview.profile");
  sheet.setString(5, 2, overview.profiles.join(", "), valueStyle);
  setLabel(6, "resultsExport.overview.machine");
  sheet.setString(6, 2, overview.machines.join(", "), valueStyle);
  setLabel(7, "resultsExport.overview.startedAt");
  const startedSerial = overview.startedAt !== null ? excelDateSerial(overview.startedAt) : null;
  if (startedSerial !== null) sheet.setNumber(7, 2, startedSerial, dateStyle);
  setLabel(8, "resultsExport.overview.finishedAt");
  const finishedSerial = overview.finishedAt !== null ? excelDateSerial(overview.finishedAt) : null;
  if (finishedSerial !== null) sheet.setNumber(8, 2, finishedSerial, dateStyle);
  setLabel(9, "resultsExport.overview.duration");
  if (overview.durationSeconds !== null) sheet.setNumber(9, 2, overview.durationSeconds, durationStyle);
  setLabel(10, "resultsExport.overview.trigger");
  sheet.setString(10, 2, overview.triggers.join(", "), valueStyle);
  setLabel(11, "resultsExport.overview.issuer");
  sheet.setString(11, 2, overview.issuers.join(", "), valueStyle);
  setLabel(12, "resultsExport.overview.settings");
  sheet.setString(12, 2, fmSettingsText(overview.fmSettings), valueStyle);

  renderCountBlock(workbook, sheet, 14, t("resultsExport.overview.scenarioSectionLabel"), [
    { label: t("resultsExport.count.total"), value: overview.scenarioTotal },
    { label: t("resultsExport.result.success"), value: overview.scenarioPassed, fill: SUCCESS_FILL },
    { label: t("resultsExport.result.failure"), value: overview.scenarioFailed, fill: FAILURE_FILL },
    { label: t("resultsExport.result.timeout"), value: overview.scenarioTimedOut, fill: TIMEOUT_FILL },
    { label: t("resultsExport.result.interrupted"), value: overview.scenarioInterrupted, fill: TIMEOUT_FILL },
    { label: t("resultsExport.result.skipped"), value: overview.scenarioSkipped, fill: SKIP_FILL },
  ]);
  renderCountBlock(workbook, sheet, 17, t("resultsExport.overview.stepSectionLabel"), [
    { label: t("resultsExport.count.total"), value: overview.stepTotal },
    { label: t("resultsExport.stepStatus.passed"), value: overview.stepPassed, fill: SUCCESS_FILL },
    { label: t("resultsExport.stepStatus.healed"), value: overview.stepHealed, fill: HEAL_FILL },
    { label: t("resultsExport.stepStatus.passedViaFallback"), value: overview.stepPassedViaFallback, fill: HEAL_FILL },
    { label: t("resultsExport.stepStatus.failed"), value: overview.stepFailed, fill: FAILURE_FILL },
    { label: t("resultsExport.stepStatus.skipped"), value: overview.stepSkipped, fill: SKIP_FILL },
  ]);

  const classesTitleStyle = workbook.registerStyle({ font: baseFont({ bold: true, size: 12 }) });
  sheet.setString(OVERVIEW_CLASS_HEADER_ROW - 1, 1, t("resultsExport.overview.classesTitle"), classesTitleStyle);

  const headerStyle = workbook.registerStyle({
    font: baseFont({ bold: true, color: "FFFFFFFF" }),
    fillArgb: HEADER_FILL,
    alignment: { horizontal: "center", vertical: "center", wrapText: true },
  });
  const classHeaderKeys = [
    "resultsExport.class.header.class",
    "resultsExport.class.header.scenarioCount",
    "resultsExport.class.header.passed",
    "resultsExport.class.header.failed",
    "resultsExport.class.header.skipped",
    "resultsExport.class.header.durationSeconds",
  ] as const;
  classHeaderKeys.forEach((key, i) => sheet.setString(OVERVIEW_CLASS_HEADER_ROW, i + 1, t(key), headerStyle));

  const textStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER });
  const numStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" } });
  const durStyle = workbook.registerStyle({
    font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" }, numFmt: DURATION_NUMFMT,
  });
  classes.forEach((cls: ResultsExportClassSummary, i) => {
    const r = OVERVIEW_CLASS_HEADER_ROW + 1 + i;
    sheet.setString(r, 1, cls.classID, textStyle);
    sheet.setNumber(r, 2, cls.scenarioCount, numStyle);
    sheet.setNumber(r, 3, cls.passedCount, numStyle);
    sheet.setNumber(r, 4, cls.failedCount, numStyle);
    sheet.setNumber(r, 5, cls.skippedCount, numStyle);
    sheet.setNumber(r, 6, cls.durationMsSum / 1000, durStyle);
  });
  sheet.setAutoFilter(`A${OVERVIEW_CLASS_HEADER_ROW}:F${OVERVIEW_CLASS_HEADER_ROW + classes.length}`);
}

/** ラベル行(色付き)+ 値行の2行ブロック(概要シートのシナリオ/ステップ集計で共用)。 */
function renderCountBlock(
  workbook: XlsxWorkbook,
  sheet: XlsxSheet,
  headingRow: number,
  heading: string,
  columns: readonly { label: string; value: number; fill?: string }[],
): void {
  const headingStyle = workbook.registerStyle({ font: baseFont({ bold: true }) });
  sheet.setString(headingRow, 1, heading, headingStyle);
  const valueStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" } });
  columns.forEach((col, i) => {
    const c = 2 + i;
    const labelStyle = workbook.registerStyle({
      font: baseFont({ bold: true, size: 9 }),
      fillArgb: col.fill,
      alignment: { horizontal: "center" },
    });
    sheet.setString(headingRow, c, col.label, labelStyle);
    sheet.setNumber(headingRow + 1, c, col.value, valueStyle);
  });
}

function renderScenariosSheet(workbook: XlsxWorkbook, sheet: XlsxSheet, model: ResultsExportModel): void {
  SCENARIOS_COLUMN_WIDTHS.forEach((w, i) => sheet.setColumnWidth(i + 1, w));

  const headerStyle = workbook.registerStyle({
    font: baseFont({ bold: true, color: "FFFFFFFF" }),
    fillArgb: HEADER_FILL,
    alignment: { horizontal: "center", vertical: "center", wrapText: true },
  });
  const headerKeys = [
    "resultsExport.scenarios.header.no",
    "resultsExport.scenarios.header.class",
    "resultsExport.scenarios.header.method",
    "resultsExport.scenarios.header.title",
    "resultsExport.scenarios.header.os",
    "resultsExport.scenarios.header.worker",
    "resultsExport.scenarios.header.machine",
    "resultsExport.scenarios.header.result",
    "resultsExport.scenarios.header.durationSeconds",
    "resultsExport.scenarios.header.startedAt",
    "resultsExport.scenarios.header.healed",
    "resultsExport.scenarios.header.failedScene",
    "resultsExport.scenarios.header.failedStep",
    "resultsExport.scenarios.header.failureKind",
    "resultsExport.scenarios.header.reason",
    "resultsExport.scenarios.header.notes",
  ] as const;
  headerKeys.forEach((key, i) => sheet.setString(1, i + 1, t(key), headerStyle));

  const plainStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER });
  const wrapStyle = workbook.registerStyle({
    font: baseFont(), border: DATA_BORDER, alignment: { vertical: "top", wrapText: true },
  });
  const numStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" } });
  const durationStyle = workbook.registerStyle({
    font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" }, numFmt: DURATION_NUMFMT,
  });
  const dateStyle = workbook.registerStyle({
    font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" }, numFmt: DATE_TIME_NUMFMT,
  });

  model.scenarios.forEach((row, i) => {
    const r = i + 2;
    sheet.setNumber(r, 1, i + 1, numStyle);
    sheet.setString(r, 2, row.className, plainStyle);
    sheet.setString(r, 3, row.method, plainStyle);
    sheet.setString(r, 4, row.title ?? row.method, wrapStyle);
    const platform = platformLabel(row.platform);
    if (platform) sheet.setString(r, 5, platform, plainStyle);
    else sheet.setStyleOnly(r, 5, plainStyle);
    if (row.worker) sheet.setString(r, 6, row.worker, plainStyle);
    else sheet.setStyleOnly(r, 6, plainStyle);
    if (row.machine) sheet.setString(r, 7, row.machine, plainStyle);
    else sheet.setStyleOnly(r, 7, plainStyle);
    const resultStyle = workbook.registerStyle({
      font: baseFont(),
      fillArgb: SCENARIO_RESULT_FILL[row.result],
      border: DATA_BORDER,
      alignment: { horizontal: "center" },
    });
    sheet.setString(r, 8, scenarioResultLabel(row.result), resultStyle);
    sheet.setNumber(r, 9, row.durationMs / 1000, durationStyle);
    const startedSerial = row.startedAt !== null ? excelDateSerial(row.startedAt) : null;
    if (startedSerial !== null) sheet.setNumber(r, 10, startedSerial, dateStyle);
    else sheet.setStyleOnly(r, 10, dateStyle);
    if (row.healedCount > 0) sheet.setNumber(r, 11, row.healedCount, numStyle);
    else sheet.setStyleOnly(r, 11, numStyle);
    if (row.failedScene !== null) {
      const label = row.failedSceneTitle !== null ? `${row.failedScene}: ${row.failedSceneTitle}` : String(row.failedScene);
      sheet.setString(r, 12, label, plainStyle);
    } else sheet.setStyleOnly(r, 12, plainStyle);
    if (row.failedStepDescription) sheet.setString(r, 13, row.failedStepDescription, wrapStyle);
    else sheet.setStyleOnly(r, 13, wrapStyle);
    if (row.failureKind) sheet.setString(r, 14, row.failureKind, plainStyle);
    else sheet.setStyleOnly(r, 14, plainStyle);
    if (row.reason) sheet.setString(r, 15, row.reason, wrapStyle);
    else sheet.setStyleOnly(r, 15, wrapStyle);
    if (row.failedStepNotes.length > 0) sheet.setString(r, 16, row.failedStepNotes.join(", "), plainStyle);
    else sheet.setStyleOnly(r, 16, plainStyle);
  });

  sheet.setAutoFilter(`A1:P${model.scenarios.length + 1}`);
}

function renderStepsSheet(workbook: XlsxWorkbook, sheet: XlsxSheet, model: ResultsExportModel): void {
  STEPS_COLUMN_WIDTHS.forEach((w, i) => sheet.setColumnWidth(i + 1, w));

  const headerStyle = workbook.registerStyle({
    font: baseFont({ bold: true, color: "FFFFFFFF" }),
    fillArgb: HEADER_FILL,
    alignment: { horizontal: "center", vertical: "center", wrapText: true },
  });
  const headerKeys = [
    "resultsExport.steps.header.class",
    "resultsExport.steps.header.method",
    "resultsExport.steps.header.scene",
    "resultsExport.steps.header.sceneTitle",
    "resultsExport.steps.header.section",
    "resultsExport.steps.header.index",
    "resultsExport.steps.header.description",
    "resultsExport.steps.header.status",
    "resultsExport.steps.header.durationSeconds",
    "resultsExport.steps.header.notes",
  ] as const;
  headerKeys.forEach((key, i) => sheet.setString(1, i + 1, t(key), headerStyle));

  const scenarioHeaderStyle = workbook.registerStyle({
    font: baseFont({ bold: true }), fillArgb: SCENARIO_HEADER_FILL, border: DATA_BORDER,
  });
  const plainStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER });
  const wrapStyle = workbook.registerStyle({
    font: baseFont(), border: DATA_BORDER, alignment: { vertical: "top", wrapText: true },
  });
  const numStyle = workbook.registerStyle({ font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" } });
  const durationStyle = workbook.registerStyle({
    font: baseFont(), border: DATA_BORDER, alignment: { horizontal: "right" }, numFmt: DURATION_NUMFMT,
  });

  let row = 2;
  for (const scenario of model.scenarios) {
    sheet.setString(row, 1, scenario.className, scenarioHeaderStyle);
    sheet.setString(row, 2, scenario.method, scenarioHeaderStyle);
    for (const c of [3, 4, 5, 6]) sheet.setStyleOnly(row, c, scenarioHeaderStyle);
    // scene 見出しの持ち場が無いので、シナリオのタイトルは説明欄(ステップ列)へ置く
    // (このシートの列にタイトル専用の列は無い。「区分」欄と揃えて読める位置が唯一ここ)。
    sheet.setString(row, 7, scenario.title ?? scenario.method, scenarioHeaderStyle);
    const scenarioResultStyle = workbook.registerStyle({
      font: baseFont({ bold: true }),
      fillArgb: SCENARIO_RESULT_FILL[scenario.result],
      border: DATA_BORDER,
      alignment: { horizontal: "center" },
    });
    sheet.setString(row, 8, scenarioResultLabel(scenario.result), scenarioResultStyle);
    for (const c of [9, 10]) sheet.setStyleOnly(row, c, scenarioHeaderStyle);
    row++;

    for (const step of scenario.timeline) {
      sheet.setString(row, 1, scenario.className, plainStyle);
      sheet.setString(row, 2, scenario.method, plainStyle);
      if (step.scene !== null) sheet.setNumber(row, 3, step.scene, numStyle);
      else sheet.setStyleOnly(row, 3, plainStyle);
      if (step.sceneTitle) sheet.setString(row, 4, step.sceneTitle, plainStyle);
      else sheet.setStyleOnly(row, 4, plainStyle);
      sheet.setString(row, 5, sectionLabel(step.section), plainStyle);
      sheet.setNumber(row, 6, step.index, numStyle);
      sheet.setString(row, 7, step.description, wrapStyle);
      const statusStyle = workbook.registerStyle({
        font: baseFont(),
        fillArgb: STEP_STATUS_FILL[step.status],
        border: DATA_BORDER,
        alignment: { horizontal: "center" },
      });
      sheet.setString(row, 8, stepStatusLabel(step.status), statusStyle);
      if (step.durationMs !== null) sheet.setNumber(row, 9, step.durationMs / 1000, durationStyle);
      else sheet.setStyleOnly(row, 9, plainStyle);
      if (step.notes.length > 0) sheet.setString(row, 10, step.notes.join(", "), plainStyle);
      else sheet.setStyleOnly(row, 10, plainStyle);
      sheet.setRowOutlineLevel(row, 1);
      row++;
    }
  }

  sheet.setAutoFilter(`A1:J${row - 1}`);
}
