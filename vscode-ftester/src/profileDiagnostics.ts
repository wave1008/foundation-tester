// profileDiagnostics.ts
// `ftester api validate-profile`(Sources/ftester/ApiValidateProfileCommand.swift)の検証結果を
// 問題パネル(DiagnosticCollection "ftester-profile")へ反映する。

import * as vscode from "vscode";
import { type CliInvocation, type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
import {
  isValidateProfileOutput,
  parseProfileFilePath,
  toDiagnosticsByPath,
  type ValidateProfileOutput,
} from "./profileModel";

const COLLECTION_NAME = "ftester-profile";
/** 位置情報が無い診断の range(各ファイルの先頭行全体)。 */
const HEAD_LINE_RANGE = new vscode.Range(0, 0, 0, Number.MAX_SAFE_INTEGER);

export function registerProfileDiagnostics(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
): void {
  const collection = vscode.languages.createDiagnosticCollection(COLLECTION_NAME);
  context.subscriptions.push(collection);

  /** validate-profile を実行する(kind/name 省略時は対象プロジェクトの全ファイル)。 */
  const runValidate = async (kind?: string, name?: string): Promise<ValidateProfileOutput | undefined> => {
    const config = getConfig();
    const resolution = resolveProjectName(workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      outputChannel.appendLine(
        "[ftester] プロファイル検証: 対象のテストプロジェクトを解決できませんでした。",
      );
      return undefined;
    }
    const args = ["api", "validate-profile", "--project", resolution.project];
    if (kind !== undefined) {
      args.push("--kind", kind);
    }
    if (name !== undefined) {
      args.push("--name", name);
    }
    if (!config.buildBeforeRun) {
      args.push("--skip-build");
    }
    const invocation: CliInvocation = {
      args,
      onLog: (line, stream) => outputChannel.appendLine(`[validate-profile ${stream}] ${line}`),
    };

    let result;
    try {
      result = await cli.invoke(config.binaryPath, workspaceRoot, invocation, "validate-profile");
    } catch (error) {
      outputChannel.appendLine(`[ftester] プロファイル検証の実行に失敗しました: ${String(error)}`);
      return undefined;
    }
    if (result.cancelled) {
      return undefined;
    }
    if (!isValidateProfileOutput(result.json)) {
      outputChannel.appendLine(
        `[ftester] プロファイル検証の出力を解析できませんでした(exit code: ${String(result.exitCode)})。`,
      );
      return undefined;
    }
    return result.json;
  };

  /** 検証結果を DiagnosticCollection に反映する。replaceAll なら反映前に全件クリアする。 */
  const applyDiagnostics = (output: ValidateProfileOutput, replaceAll: boolean): void => {
    if (replaceAll) {
      collection.clear();
    }
    for (const [filePath, diagnosticsForFile] of toDiagnosticsByPath(output)) {
      const uri = vscode.Uri.file(filePath);
      const diagnostics: vscode.Diagnostic[] = [
        ...diagnosticsForFile.errors.map(
          (message) => new vscode.Diagnostic(HEAD_LINE_RANGE, message, vscode.DiagnosticSeverity.Error),
        ),
        ...diagnosticsForFile.warnings.map(
          (message) => new vscode.Diagnostic(HEAD_LINE_RANGE, message, vscode.DiagnosticSeverity.Warning),
        ),
      ];
      for (const diagnostic of diagnostics) {
        diagnostic.source = "ftester";
      }
      // 空配列は「クリーン(問題なし)」の意味で、既存の診断があれば消える。
      collection.set(uri, diagnostics);
    }
  };

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument(async (document) => {
      const location = parseProfileFilePath(workspaceRoot, document.uri.fsPath);
      if (!location) {
        return;
      }
      const output = await runValidate(location.kind, location.name);
      if (!output) {
        return;
      }
      if (output.results.length === 0) {
        // 同名ファイルが見つからない(削除・リネーム直後等)場合は既存診断を消す。
        collection.delete(document.uri);
        return;
      }
      applyDiagnostics(output, false);
    }),
    vscode.commands.registerCommand("ftester.validateProfiles", async () => {
      const output = await runValidate();
      if (!output) {
        void vscode.window.showWarningMessage(
          "ftester: プロファイルの検証に失敗しました。対象プロジェクト(ftester.project)や出力パネル「ftester」を確認してください。",
        );
        return;
      }
      applyDiagnostics(output, true);

      const errorFiles = output.results.filter((result) => result.errors.length > 0).length;
      const warningOnlyFiles = output.results.filter(
        (result) => result.errors.length === 0 && result.warnings.length > 0,
      ).length;
      const cleanFiles = output.results.length - errorFiles - warningOnlyFiles;
      void vscode.window.showInformationMessage(
        `ftester: プロファイルを検証しました(${String(output.results.length)}件中` +
          ` エラー ${String(errorFiles)}件・警告 ${String(warningOnlyFiles)}件・問題なし ${String(cleanFiles)}件)。`,
      );
    }),
  );
}
