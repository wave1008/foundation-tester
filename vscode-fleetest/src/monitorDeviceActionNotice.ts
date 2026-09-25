// 実機の起動で「端末の前で人がやること」(CLI の deviceAction)を VSCode の通知で促す。
// タイルの文言だけでは利用者は端末を手に取らない(ユーザー指摘)。
// **待ちが終わったら(action:null)通知を消す**(ユーザー指示)。拡張から閉じられるのは
// 進捗型(withProgress)だけなので、それで出す(showWarningMessage は閉じられず、解除後も残る)。
// 出したことは OUTPUT にも残す(通知が見えなかったとき「作られたか」を後から確かめるため)。
// 鍵は (machine, name)。同じ台・同じ action が重なっても通知は1枚。action が変われば張り替える
// (ロック解除の直後に承認プロンプトが出る順が普通)。
// **CLI が action:null を出さずに終わった(クラッシュ・kill)ときは呼び手が release する**
// (monitorDeviceOps.ts の close ハンドラ)。放っておくと通知が消えない。
import * as vscode from "vscode";
import { t } from "./i18n";
import type { DeviceUserAction } from "./monitorDeviceLifecycle";

export interface DeviceActionNoticeUi {
  /** 通知を出し、返した Promise が解決するまで表示し続ける */
  show(message: string, until: Promise<void>): void;
}

const vscodeUi: DeviceActionNoticeUi = {
  show(message, until) {
    void vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: message, cancellable: false },
      () => until,
    );
  },
};

function noticeTitle(action: DeviceUserAction, name: string, machine: string | undefined): string {
  switch (action) {
    case "unlock":
      return machine
        ? t("deviceOps.unlockDeviceNoticeRemote", { name, machine })
        : t("deviceOps.unlockDeviceNotice", { name });
    case "approveAutomation":
      return machine
        ? t("deviceOps.approveAutomationNoticeRemote", { name, machine })
        : t("deviceOps.approveAutomationNotice", { name });
  }
}

export class DeviceActionNotices {
  private readonly open = new Map<string, { readonly action: DeviceUserAction; readonly close: () => void }>();

  constructor(
    private readonly log: (line: string) => void,
    private readonly ui: DeviceActionNoticeUi = vscodeUi,
  ) {}

  private static key(name: string, machine: string | undefined): string {
    return `${machine ?? ""}\t${name}`;
  }

  update(name: string, machine: string | undefined, action: DeviceUserAction | null): void {
    const key = DeviceActionNotices.key(name, machine);
    if (this.open.get(key)?.action === action) {
      return;
    }
    this.release(name, machine);
    if (action === null) {
      return;
    }
    let close: () => void = () => {};
    const until = new Promise<void>((resolve) => { close = resolve; });
    this.open.set(key, { action, close });
    const message = noticeTitle(action, name, machine);
    this.log(t("deviceOps.log.deviceActionNotified", { message }));
    this.ui.show(message, until);
  }

  /** 通知を閉じる(待ちの終わり・CLI の終了) */
  release(name: string, machine: string | undefined): void {
    const key = DeviceActionNotices.key(name, machine);
    const entry = this.open.get(key);
    if (entry) {
      this.open.delete(key);
      entry.close();
    }
  }

  openAction(name: string, machine: string | undefined): DeviceUserAction | undefined {
    return this.open.get(DeviceActionNotices.key(name, machine))?.action;
  }
}
