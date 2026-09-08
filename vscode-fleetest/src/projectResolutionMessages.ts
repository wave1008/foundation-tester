// projectResolution.ts の "missing" 判定を利用者向け文言にする。t() を使うため vscode 依存
// (projectResolution.ts 自体は vscode 非依存を保つのでここに分離)。複数の呼び出し元
// (monitorProcessManager.ts / testTree.ts)が同じ文言を書かずに済むよう、ここ1箇所へ集約する。
import { t } from "./i18n";

/** fleetest.project が候補に無い名前を指しているときの警告文(設定名・指している名前・
 * 実在する候補の3つを含む)。 */
export function missingProjectMessage(project: string, candidates: readonly string[]): string {
  const candidatesText =
    candidates.length > 0 ? candidates.join(", ") : t("workbench.project.missingNoCandidates");
  return t("workbench.project.missingWarning", { name: project, candidates: candidatesText });
}
