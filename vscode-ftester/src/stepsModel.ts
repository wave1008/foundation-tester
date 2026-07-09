// stepsModel.ts
// `ftester api steps` の出力(StepRow[])を、ステップ一覧 TreeView 用のノードモデルに変換する
// 純粋関数群。vscode モジュールに一切依存しない(stepsView.ts からも test/stepsModel.test.mjs
// からも同じロジックを使えるようにするため)。
//
// 変換規則:
//   - scene(シーン番号)ごとにグループ化する。グループの並び順は「最初にそのシーン番号が
//     出現した順」を保持する(シーン番号でソートし直したりはしない)。
//   - グループ内のステップの並び順は入力(StepRow[])の並び順をそのまま保持する。
//   - ステップの description は comment を優先し、無ければ generatedComment、
//     どちらも無ければ空文字列にフォールバックする。

import type { StepRow, StepSection } from "./model";

/** scene グループ1件分のノード。 */
export interface StepTreeSceneNode {
  readonly kind: "scene";
  readonly scene: number;
  readonly sceneTitle: string;
  /** 表示ラベル(`scene <N>: <sceneTitle>`)。 */
  readonly label: string;
  readonly steps: readonly StepTreeStepNode[];
}

/** ステップ1件分のノード。 */
export interface StepTreeStepNode {
  readonly kind: "step";
  readonly index: number;
  readonly scene: number;
  readonly section: StepSection;
  readonly command: string;
  /** 表示ラベル(`<index>. <command>`)。 */
  readonly label: string;
  /** TreeItem.description 相当(comment ?? generatedComment ?? ""）。 */
  readonly description: string;
  /** TreeItem.tooltip 相当(区分 + コメント全文)。 */
  readonly tooltip: string;
  /** リポジトリルート相対パス(StepRow.file をそのまま引き継ぐ)。 */
  readonly file: string;
  readonly line: number;
}

/** StepRow[] を scene グループのノード配列に変換する。 */
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
  const tooltipLines = [`区分: ${step.section}`];
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
