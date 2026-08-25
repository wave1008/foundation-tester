// debugConfig.ts
// fleetest デバッグの vscode 側配線(DebugAdapterDescriptorFactory / ConfigurationProvider)。
// DAP のリクエスト/イベント変換は debugAdapter.ts(vscode 非依存)側にある。

import * as vscode from "vscode";
import { type FleetestConfig, resolveProjectName } from "./config";
import { FleetestDebugSession } from "./debugAdapter";
import { t } from "./i18n";

export function registerDebugAdapter(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FleetestConfig,
  outputChannel: vscode.OutputChannel,
): void {
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider(
      "fleetest",
      new FleetestDebugConfigurationProvider(workspaceRoot, getConfig),
    ),
    vscode.debug.registerDebugAdapterDescriptorFactory(
      "fleetest",
      new FleetestDebugAdapterDescriptorFactory(workspaceRoot, getConfig, outputChannel),
    ),
  );
}

class FleetestDebugConfigurationProvider implements vscode.DebugConfigurationProvider {
  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FleetestConfig,
  ) {}

  resolveDebugConfiguration(
    _folder: vscode.WorkspaceFolder | undefined,
    config: vscode.DebugConfiguration,
  ): vscode.ProviderResult<vscode.DebugConfiguration> {
    if (!config.type && !config.request && !config.scenario) {
      // launch.json 未設定のまま「デバッグの開始」を叩いた等、対象不明の起動は何もしない。
      return null;
    }
    if (typeof config.scenario !== "string" || config.scenario.trim().length === 0) {
      void vscode.window.showErrorMessage(t("run.debug.scenarioRequired"));
      return undefined;
    }
    if (typeof config.project !== "string" || config.project.trim().length === 0) {
      const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
      if (resolution.kind === "resolved") {
        config.project = resolution.project;
      } else {
        void vscode.window.showErrorMessage(`fleetest: ${t("run.project.unresolvedHint")}`);
        return undefined;
      }
    }
    return config;
  }
}

class FleetestDebugAdapterDescriptorFactory implements vscode.DebugAdapterDescriptorFactory {
  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FleetestConfig,
    private readonly outputChannel: vscode.OutputChannel,
  ) {}

  createDebugAdapterDescriptor(
    _session: vscode.DebugSession,
    _executable: vscode.DebugAdapterExecutable | undefined,
  ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
    const config = this.getConfig();
    const debugSession = new FleetestDebugSession({
      binaryPath: config.binaryPath,
      cwd: this.workspaceRoot,
      log: (line, stream) => this.outputChannel.appendLine(`[${stream}] ${line}`),
    });
    return new vscode.DebugAdapterInlineImplementation(debugSession as unknown as vscode.DebugAdapter);
  }
}
