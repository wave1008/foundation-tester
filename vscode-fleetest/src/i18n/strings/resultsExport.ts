// 辞書(拡張側)。namespace: resultsExport.
// 対象ソース: resultsExportWorkbook.ts(「テストセッション」タブのエクスポート .xlsx に直接書き込む文言)。
import type { MessageDict } from "../core";

export const resultsExportStrings = {
  "resultsExport.sheet.overview": { ja: "概要", en: "Overview" },
  "resultsExport.sheet.scenarios": { ja: "シナリオ", en: "Scenarios" },
  "resultsExport.sheet.steps": { ja: "ステップ", en: "Steps" },

  "resultsExport.overview.title": { ja: "テスト結果 — {project}", en: "Test Results — {project}" },
  "resultsExport.overview.project": { ja: "プロジェクト", en: "Project" },
  "resultsExport.overview.session": { ja: "セッション", en: "Session" },
  "resultsExport.overview.profile": { ja: "実行プロファイル", en: "Profile" },
  "resultsExport.overview.machine": { ja: "マシン", en: "Machine" },
  "resultsExport.overview.startedAt": { ja: "開始", en: "Started" },
  "resultsExport.overview.finishedAt": { ja: "終了", en: "Finished" },
  "resultsExport.overview.duration": { ja: "所要", en: "Duration" },
  "resultsExport.overview.trigger": { ja: "起動元", en: "Trigger" },
  "resultsExport.overview.issuer": { ja: "実行者", en: "Issuer" },
  "resultsExport.overview.settings": { ja: "設定", en: "Settings" },
  "resultsExport.overview.scenarioSectionLabel": { ja: "シナリオ", en: "Scenarios" },
  "resultsExport.overview.stepSectionLabel": { ja: "ステップ", en: "Steps" },
  "resultsExport.overview.classesTitle": { ja: "クラス別", en: "By Class" },

  // FM 設定(4つ常に同じ順で「ラベル=ON/OFF」を並べる。docs/results-json.md の fmSettings)。
  "resultsExport.fm.heal": { ja: "自己修復", en: "Self-heal" },
  "resultsExport.fm.fmTextOcclusionCheck": { ja: "テキストの視覚検証", en: "Text visual verification" },
  "resultsExport.fm.ocrTextOcclusionCheck": { ja: "OCRを使ったテキストの視覚検証", en: "OCR text visual verification" },
  "resultsExport.fm.screenLooksLike": { ja: "画面の見た目判定", en: "Screen appearance check" },
  "resultsExport.fm.on": { ja: "ON", en: "ON" },
  "resultsExport.fm.off": { ja: "OFF", en: "OFF" },

  "resultsExport.count.total": { ja: "合計", en: "Total" },

  // シナリオの結果(概要の集計ラベル・シナリオシートの「結果」列で共用)。
  "resultsExport.result.success": { ja: "成功", en: "Success" },
  "resultsExport.result.failure": { ja: "失敗", en: "Failure" },
  "resultsExport.result.timeout": { ja: "タイムアウト", en: "Timeout" },
  "resultsExport.result.interrupted": { ja: "中断", en: "Interrupted" },
  "resultsExport.result.skipped": { ja: "スキップ", en: "Skipped" },

  // timeline のステップ状態(概要の集計ラベル・ステップシートの「状態」列で共用)。
  "resultsExport.stepStatus.passed": { ja: "成功", en: "Success" },
  "resultsExport.stepStatus.passedViaFallback": { ja: "代替で成功", en: "Passed via fallback" },
  "resultsExport.stepStatus.healed": { ja: "自己修復", en: "Healed" },
  "resultsExport.stepStatus.failed": { ja: "失敗", en: "Failed" },
  "resultsExport.stepStatus.skipped": { ja: "未実行", en: "Not run" },

  "resultsExport.class.header.class": { ja: "クラス", en: "Class" },
  "resultsExport.class.header.scenarioCount": { ja: "シナリオ数", en: "Scenarios" },
  "resultsExport.class.header.passed": { ja: "成功", en: "Success" },
  "resultsExport.class.header.failed": { ja: "失敗", en: "Failure" },
  "resultsExport.class.header.skipped": { ja: "スキップ", en: "Skipped" },
  "resultsExport.class.header.durationSeconds": { ja: "所要(秒)", en: "Duration (s)" },

  "resultsExport.scenarios.header.no": { ja: "No", en: "No" },
  "resultsExport.scenarios.header.class": { ja: "クラス", en: "Class" },
  "resultsExport.scenarios.header.method": { ja: "シナリオ", en: "Scenario" },
  "resultsExport.scenarios.header.title": { ja: "タイトル", en: "Title" },
  "resultsExport.scenarios.header.os": { ja: "OS", en: "OS" },
  "resultsExport.scenarios.header.worker": { ja: "台", en: "Device" },
  "resultsExport.scenarios.header.machine": { ja: "マシン", en: "Machine" },
  "resultsExport.scenarios.header.result": { ja: "結果", en: "Result" },
  "resultsExport.scenarios.header.durationSeconds": { ja: "所要(秒)", en: "Duration (s)" },
  "resultsExport.scenarios.header.startedAt": { ja: "開始", en: "Started" },
  "resultsExport.scenarios.header.healed": { ja: "自己修復", en: "Self-heal" },
  "resultsExport.scenarios.header.failedScene": { ja: "失敗した scene", en: "Failed Scene" },
  "resultsExport.scenarios.header.failedStep": { ja: "失敗したステップ", en: "Failed Step" },
  "resultsExport.scenarios.header.failureKind": { ja: "失敗の経路", en: "Failure Kind" },
  "resultsExport.scenarios.header.reason": { ja: "理由", en: "Reason" },
  "resultsExport.scenarios.header.notes": { ja: "注記", en: "Notes" },

  "resultsExport.steps.header.class": { ja: "クラス", en: "Class" },
  "resultsExport.steps.header.method": { ja: "シナリオ", en: "Scenario" },
  "resultsExport.steps.header.scene": { ja: "scene", en: "scene" },
  "resultsExport.steps.header.sceneTitle": { ja: "scene 見出し", en: "Scene Title" },
  "resultsExport.steps.header.section": { ja: "区分", en: "Section" },
  "resultsExport.steps.header.index": { ja: "#", en: "#" },
  "resultsExport.steps.header.description": { ja: "ステップ", en: "Step" },
  "resultsExport.steps.header.status": { ja: "状態", en: "Status" },
  "resultsExport.steps.header.durationSeconds": { ja: "所要(秒)", en: "Duration (s)" },
  "resultsExport.steps.header.notes": { ja: "注記", en: "Notes" },

  "resultsExport.section.condition": { ja: "事前条件", en: "Condition" },
  "resultsExport.section.action": { ja: "操作", en: "Action" },
  "resultsExport.section.expectation": { ja: "期待結果", en: "Expectation" },
  "resultsExport.section.setUp": { ja: "setUp", en: "setUp" },
  "resultsExport.section.tearDown": { ja: "tearDown", en: "tearDown" },
} satisfies MessageDict;
