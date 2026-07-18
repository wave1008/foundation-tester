// liveDeps.ts
// MonitorLiveController(monitorLiveController.ts)への窓口。旧 MonitorPanelDeps からライブ操作に
// 必要なフィールドだけを切り出したもの(実装: livePanel.ts の LivePanelController)。

import type * as vscode from "vscode";
import type { FtesterConfig } from "./config";
import type { LiveToWebviewEnvelope } from "./liveModel";
import type { MonitorToWebviewMessage } from "./monitorModel";

export interface LiveDeps {
  readonly workspaceRoot: string;
  getConfig(): FtesterConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(
    message: LiveToWebviewEnvelope | Extract<MonitorToWebviewMessage, { readonly type: "liveH264Chunk" }>,
  ): void;
  /** パネルが開いているか。scheduleServeRestart() の5秒後再起動タイマーが使う。 */
  isPanelActive(): boolean;
  /** 設定タブの「ポーリングモードを使用する」現在値(デバイスモニターと workspaceState を共有)。 */
  isPollingMode(): boolean;
  /** 生成したソース(絶対パス)をパネルの隣の列に開く(レコーディング→gen-scenario 完了時に使う)。 */
  openGeneratedDocument(filePath: string): void;
}
