// healNotice.ts
// 自己修復で直したセレクタの件数を、dry-run ではない run の終了時に通知する(書き戻しは CLI が run の終わりに行う)。
// RunEventBus は runHandler.ts と同じインスタンスを受ける。

import * as vscode from "vscode";
import { countDistinctFixes, HealFixCollector } from "./healModel";
import { t } from "./i18n";
import type { RunBusMessage, RunEventBus } from "./runEventBus";

export function registerHealNotice(context: vscode.ExtensionContext, eventBus: RunEventBus): void {
  const collector = new HealFixCollector();
  const unsubscribe = eventBus.subscribe((message: RunBusMessage) => {
    switch (message.type) {
      case "runStarted":
        collector.begin(message.isDryRun);
        break;
      case "event":
        collector.collect(message.event);
        break;
      case "runEnded": {
        if (collector.isEmpty()) {
          break;
        }
        const count = countDistinctFixes(collector.list());
        const showChanges = t("exploreHeal.heal.notice.showChanges");
        void vscode.window
          .showInformationMessage(t("exploreHeal.heal.notice.message", { count }), showChanges)
          .then((picked) => {
            if (picked === showChanges) {
              return vscode.commands.executeCommand("workbench.view.scm");
            }
            return undefined;
          });
        break;
      }
    }
  });
  context.subscriptions.push({ dispose: unsubscribe });
}
