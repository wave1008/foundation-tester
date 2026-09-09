// stepsModel.ts
// `fleetest api steps` の出力を TreeView 用ノードモデルに変換する純粋関数群。
// vscode モジュールに依存しない(stepsView.ts と test/stepsModel.test.mjs の両方から使うため)。
//
// scene グループの並び順は最初にそのシーン番号が出現した順(ソートし直さない)。

import { t } from "./i18n";
import type { StepRow, StepSection } from "./model";

/** dry-run が出した警告(StepsResult.warnings)1件分のノード。TreeView の先頭に scene より
 * 前置して出す(fetchSteps が届けた警告は既に握りつぶされていた=空の expectation ブロック・
 * 台帳に無い #id 等。ApiSteps.warnings の doc 参照)。 */
export interface StepTreeWarningNode {
  readonly kind: "warning";
  /** ApiSteps.warnings が返す生の文言(⚠️ 接頭辞込み)。 */
  readonly message: string;
  /** TreeItem.label 相当。 */
  readonly label: string;
  /** TreeItem.tooltip 相当。 */
  readonly tooltip: string;
}

export function buildWarningNodes(warnings: readonly string[]): StepTreeWarningNode[] {
  return warnings.map((message) => ({
    kind: "warning",
    message,
    label: message,
    tooltip: `${t("workbench.stepsView.warningTooltip")}\n${message}`,
  }));
}

export interface StepTreeSceneNode {
  readonly kind: "scene";
  readonly scene: number;
  readonly sceneTitle: string;
  /** TreeItem.label 相当。 */
  readonly label: string;
  readonly steps: readonly StepTreeStepNode[];
}

export interface StepTreeStepNode {
  readonly kind: "step";
  readonly index: number;
  readonly scene: number;
  readonly section: StepSection;
  readonly command: string;
  /** TreeItem.label 相当。 */
  readonly label: string;
  /** TreeItem.description 相当(comment ?? generatedComment ?? "")。 */
  readonly description: string;
  /** TreeItem.tooltip 相当(区分 + コメント全文)。 */
  readonly tooltip: string;
  /** リポジトリルート相対パス(StepRow.file をそのまま引き継ぐ)。 */
  readonly file: string;
  readonly line: number;
}

export function buildStepTree(steps: readonly StepRow[]): StepTreeSceneNode[] {
  const sceneOrder: number[] = [];
  const groups = new Map<number, { sceneTitle: string; steps: StepTreeStepNode[] }>();

  for (const step of steps) {
    let group = groups.get(step.scene);
    if (!group) {
      group = { sceneTitle: step.sceneTitle, steps: [] };
      groups.set(step.scene, group);
      sceneOrder.push(step.scene);
    }
    group.steps.push(toStepNode(step));
  }

  return sceneOrder.map((scene) => {
    const group = groups.get(scene)!;
    return {
      kind: "scene",
      scene,
      sceneTitle: group.sceneTitle,
      label: `scene ${String(scene)}: ${group.sceneTitle}`,
      steps: group.steps,
    };
  });
}

function toStepNode(step: StepRow): StepTreeStepNode {
  const description = step.comment ?? step.generatedComment ?? "";
  const tooltipLines = [t("workbench.stepsModel.sectionLabel", { section: step.section })];
  const commentText = step.comment ?? step.generatedComment;
  if (commentText) {
    tooltipLines.push(commentText);
  }
  return {
    kind: "step",
    index: step.index,
    scene: step.scene,
    section: step.section,
    command: step.command,
    label: `${String(step.index)}. ${step.command}`,
    description,
    tooltip: tooltipLines.join("\n"),
    file: step.file,
    line: step.line,
  };
}
