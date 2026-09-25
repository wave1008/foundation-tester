// monitorDeviceCreateOps.ts
// プロファイルタブのデバイス追加/削除(create-device・delete-device・install-system-image)を担う。
// MonitorDeviceOps(monitorDeviceOps.ts)が内部に1つ保持し、既存の public メソッドはここへ委譲する
// (サブコントローラ間の直接参照禁止。deps は MonitorPanelDeps の狭いサブセット)。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable } from "node:stream";
import * as vscode from "vscode";
import { childEnv } from "./childEnv";
import { resolveProjectName } from "./config";
import { t } from "./i18n";
import {
  deleteDeviceApiArgs,
  installSystemImageApiArgs,
  isCreateDeviceEvent,
  isDeleteDeviceEvent,
  isInstallSystemImageEvent,
  type MonitorFromWebviewMessage,
} from "./monitorModel";
import { LOCAL_MACHINE_KEY } from "./runBoardModel";
import { NdjsonParser } from "./ndjson";
import type { MonitorPanelDeps } from "./monitorPanel";
import { type DeviceCommandSource, deviceCommandArgs } from "./remoteRunArgs";
import {
  installSystemImageBatchConfirmMessage,
  installSystemImageConfirmMessage,
  occupancyDetailLine,
  withSourceContext,
} from "./monitorDeviceOpsText";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(monitorDeviceOps.ts の PipeProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** webview からの "createDevice" メッセージの形(runCreateDevice で使う)。 */
export type CreateDeviceMessage = Extract<MonitorFromWebviewMessage, { type: "createDevice" }>;

/** webview からの "batchCreateDevices" メッセージの形(runBatchCreateDevices で使う)。 */
export type BatchCreateDevicesMessage = Extract<MonitorFromWebviewMessage, { type: "batchCreateDevices" }>;

/** spawnCreateDevice の1台ぶんの結果。バッチが1台ずつ受け取るために使う
 *  (単発は従来どおり createDeviceResult を post するので渡さない)。 */
type CreateDeviceOutcome = {
  readonly ok: boolean;
  readonly error: string | null;
  readonly device: { readonly avd: string | null; readonly udid: string | null } | null;
};
type CreateDeviceOutcomeHandler = (outcome: CreateDeviceOutcome) => void;

/** webview からの "devicePickDeviceDelete" メッセージの形(runDeleteDevice で使う)。 */
export type DevicePickDeviceDeleteMessage = Extract<MonitorFromWebviewMessage, { type: "devicePickDeviceDelete" }>;

/** MonitorDeviceCreateOps が要る MonitorPanelDeps の部分集合だけを束ねる(コントローラ分割規約:
 * 狭い deps インターフェースをコンストラクタ注入し、サブコントローラ同士は直接参照しない)。 */
export interface MonitorDeviceCreateOpsDeps {
  readonly workspaceRoot: MonitorPanelDeps["workspaceRoot"];
  getConfig: MonitorPanelDeps["getConfig"];
  readonly outputChannel: MonitorPanelDeps["outputChannel"];
  post: MonitorPanelDeps["post"];
  notifyProjectDeviceCatalogChanged: MonitorPanelDeps["notifyProjectDeviceCatalogChanged"];
  unregisterDeletedDevice: MonitorPanelDeps["unregisterDeletedDevice"];
  machineLock: MonitorPanelDeps["machineLock"];
}

/** プロファイルタブ: デバイスカタログへの追加(create-device/install-system-image)・削除
 * (delete-device)の短命プロセス実行を担う。いずれもデバイスライフサイクルの直列キュー
 * (MonitorDeviceOps.lifecycleQueue)には載せない —— 参照系の単発コマンドか、モーダル側の
 * 1件実行ガード(creatingDevice/deletingIdentifiers)で十分であり、simctl/adb 起動系のキューと
 * 競合する処理ではないため。 */
export class MonitorDeviceCreateOps {
  /** create-device の多重実行ガード。true の間に来た createDevice リクエストは即座に失敗を返す。 */
  private creatingDevice = false;
  /** delete-device の多重実行ガード(identifier 単位)。行ごとに独立して走らせるため creatingDevice と
   * 違い Set にする(他の行の削除は妨げない。webview 側もその行の checkbox を disabled にして
   * 連打を防ぐが、直後の再送・別経路からの二重送信に対する保険として持つ)。 */
  private readonly deletingIdentifiers = new Set<string>();

  constructor(private readonly deps: MonitorDeviceCreateOpsDeps) {}

  /**
   * `fleetest api create-device` を短命プロセスとして実行する(デバイス追加モーダルの OK)。
   * creatingDevice による多重実行防止(モーダル側のボタン無効化に加えた保険)。source が remote
   * なら、実行環境を変え得る破壊的操作として先にホスト側 modal 確認を挟む(§13。照会系の
   * device-catalog/installed-devices は確認不要)。確認を待つ間も多重実行防止は効かせる
   * (creatingDevice を確認前に true にする)。
   */
  runCreateDevice(msg: CreateDeviceMessage): void {
    if (this.creatingDevice) {
      this.deps.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: t("deviceOps.createAlreadyRunning"),
        device: null,
      });
      return;
    }
    this.creatingDevice = true;
    // ダウンロードが要る OS バージョンを選んだ場合は、上書き/リモートの確認とは統合した
    // 1枚のモーダル(ライセンス同意)だけを出す(2枚続けて出さない。§13/2026-08-25 の規律と同じ)。
    if (msg.installSystemImage) {
      void this.confirmAndInstallThenCreate(msg, msg.installSystemImage);
      return;
    }
    // 上書き(既存の実体を消して作り直す)は破壊的なので、ローカル・リモートを問わず確認する。
    // リモートの確認文はマシン名も出す(どの機械の実体を消すかが要点)
    if (msg.overwrite) {
      void this.confirmAndSpawnCreateDevice(msg, msg.source.kind === "remote" ? msg.source.machine : null);
      return;
    }
    if (msg.source.kind === "remote") {
      void this.confirmAndSpawnCreateDevice(msg, msg.source.machine);
      return;
    }
    this.spawnCreateDevice(msg);
  }

  /**
   * 「デバイスを追加」左下の「バッチ作成」: 同じ設定で names を**1台ずつ順に**作る。
   *
   * **並列にしない** —— simctl/avdmanager は同時実行で相互に失敗し得るうえ、進行窓は
   * 「いま何台目か」を示すのが役目なので、順に確定させたほうが読める。
   *
   * 確認は **1枚だけ**(webview では出せないのでホスト側 modal)。何台をどこへ作るかを聞き、
   * 既存を消して作り直すぶんがあれば同じ文面に書き足してボタンの文言を変える。
   * 断られたら **started を出さずに** finished(started:false)で戻す
   * (webview は追加ダイアログを開いたまま元に戻す)。
   *
   * 1台でも失敗しても残りは続ける(N 台中1台の失敗を致命にしない)。結果は finished の
   * created/failed に分けて返し、webview が一覧に出す。
   */
  async runBatchCreateDevices(msg: BatchCreateDevicesMessage): Promise<void> {
    const abort = (error: string): void => {
      this.deps.post({
        type: "batchCreateFinished",
        started: false,
        created: [],
        failed: [],
        error,
      });
    };
    if (this.creatingDevice) {
      abort(t("deviceOps.batchAlreadyRunning"));
      return;
    }
    this.creatingDevice = true;
    try {
      const machine = msg.source.kind === "remote" ? msg.source.machine : t("deviceOps.createOverwriteLocalMachine");
      // 検証(isMonitorFromWebviewMessage)で names.length > 0 は保証済み。?? は型のためだけ
      const first = msg.names[0] ?? "";
      const last = msg.names[msg.names.length - 1] ?? "";
      const install = msg.installSystemImage;
      // **確認は1回だけ**(2026-08-25 指示)。上書き・ダウンロード導入が要るときは同じ文面(または
      // installSystemImageBatchConfirmMessage)に書き足す —— 2枚に分けると、2枚目を断ったときに
      // **衝突していないぶんまで巻き添えで中止**になり、「どこまで作られたのか」が押した人にも分からない
      let message: string;
      let confirmLabel: string;
      let detail: string | undefined;
      if (install) {
        message = installSystemImageBatchConfirmMessage({
          machine, count: msg.names.length, first, last,
          packageName: install.package, sizeBytes: install.sizeBytes, license: install.license,
        });
        const detailLines = [
          msg.overwriteNames.length > 0
            ? t("deviceOps.installSystemImageBatchOverwriteNote", {
                machine, count: String(msg.overwriteNames.length), names: msg.overwriteNames.join(", "),
              })
            : undefined,
          this.occupancyDetail(msg.source.kind === "remote" ? msg.source.machine : null),
          t("deviceOps.installSystemImageLicenseHint"),
        ].filter((line): line is string => line !== undefined);
        detail = detailLines.join("\n\n");
        confirmLabel = t("deviceOps.installSystemImageConfirmButton");
      } else {
        const overwriteNote = msg.overwriteNames.length > 0
          ? t("deviceOps.batchOverwriteNote", {
              machine,
              count: String(msg.overwriteNames.length),
              names: msg.overwriteNames.join(", "),
            })
          : "";
        message = t("deviceOps.batchConfirmMessage", { machine, count: String(msg.names.length), first, last })
          + overwriteNote;
        confirmLabel = msg.overwriteNames.length > 0
          ? t("deviceOps.batchOverwriteConfirmButton")
          : t("deviceOps.batchConfirmButton");
      }
      const choice = await vscode.window.showWarningMessage(message, { modal: true, detail }, confirmLabel);
      if (choice !== confirmLabel) {
        abort(t("deviceOps.createCancelled"));
        return;
      }
      if (install) {
        this.deps.post({ type: "deviceAddProgress", phase: "installing" });
        const installOutcome = await new Promise<{ ok: boolean; error: string | null }>((resolve) => {
          this.spawnInstallSystemImage(install.package, msg.source, (ok, error) => resolve({ ok, error }));
        });
        if (!installOutcome.ok) {
          abort(installOutcome.error ?? t("deviceOps.installSystemImageFailedGeneric"));
          return;
        }
      }
      this.deps.post({ type: "batchCreateStarted", names: msg.names });
      const overwrite = new Set(msg.overwriteNames);
      const created: { name: string; avd: string | null; udid: string | null }[] = [];
      const failed: { name: string; error: string | null }[] = [];
      for (const [index, name] of msg.names.entries()) {
        this.deps.post({ type: "batchCreateProgress", index, name, state: "running", error: null });
        const outcome = await new Promise<CreateDeviceOutcome>((resolve) => {
          this.spawnCreateDevice(
            {
              type: "createDevice",
              platform: msg.platform,
              name,
              model: msg.model,
              os: msg.os,
              // 登録はピッカーの OK(runProfileDevicesSync)が行う。ここは物理作成だけ
              register: false,
              overwrite: overwrite.has(name),
              source: msg.source,
            },
            resolve,
          );
        });
        if (outcome.ok) {
          created.push({ name, avd: outcome.device?.avd ?? null, udid: outcome.device?.udid ?? null });
        } else {
          failed.push({ name, error: outcome.error });
        }
        this.deps.post({
          type: "batchCreateProgress",
          index,
          name,
          state: outcome.ok ? "ok" : "failed",
          error: outcome.error,
        });
      }
      this.deps.post({ type: "batchCreateFinished", started: true, created, failed, error: null });
    } finally {
      this.creatingDevice = false;
    }
  }

  /** リモート作成の modal 確認(§11・§13 と同じ showWarningMessage({modal:true}) 方式。
   * webview の window.confirm は効かないため必ずホスト側で行う)。 */
  private async confirmAndSpawnCreateDevice(msg: CreateDeviceMessage, machine: string | null): Promise<void> {
    const overwrite = msg.overwrite === true;
    const confirmLabel = overwrite
      ? t("deviceOps.createOverwriteConfirmButton")
      : t("deviceOps.createRemoteConfirmButton");
    const where = machine ?? t("deviceOps.createOverwriteLocalMachine");
    const message = overwrite
      ? t("deviceOps.createOverwriteConfirmMessage", { machine: where, name: msg.name })
      : t("deviceOps.createRemoteConfirmMessage", { machine: where, name: msg.name });
    const choice = await vscode.window.showWarningMessage(
      message,
      { modal: true, detail: this.occupancyDetail(machine) },
      confirmLabel,
    );
    if (choice !== confirmLabel) {
      this.creatingDevice = false;
      this.deps.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: t("deviceOps.createCancelled"),
        device: null,
      });
      return;
    }
    this.spawnCreateDevice(msg);
  }

  /**
   * ダウンロードが要る Android OS バージョンを選んだときの「デバイスを追加」OK(runCreateDevice から)。
   * **確認は1枚だけ**(上書き・リモートの確認とは統合する。confirmAndSpawnCreateDevice を分岐で
   * 使い分けない — 2枚続けて聞かない §13/2026-08-25 の規律)。同意を得てから
   * `install-system-image` を実行し、成功したときだけ通常の spawnCreateDevice へ進む。
   */
  private async confirmAndInstallThenCreate(
    msg: CreateDeviceMessage,
    install: NonNullable<CreateDeviceMessage["installSystemImage"]>,
  ): Promise<void> {
    const machine = msg.source.kind === "remote" ? msg.source.machine : null;
    const where = machine ?? t("deviceOps.createOverwriteLocalMachine");
    const message = installSystemImageConfirmMessage({
      machine: where,
      name: msg.name,
      packageName: install.package,
      sizeBytes: install.sizeBytes,
      license: install.license,
    });
    const detailLines = [
      msg.overwrite
        ? t("deviceOps.installSystemImageOverwriteNote", { machine: where, name: msg.name })
        : undefined,
      this.occupancyDetail(machine),
      t("deviceOps.installSystemImageLicenseHint"),
    ].filter((line): line is string => line !== undefined);
    const confirmLabel = t("deviceOps.installSystemImageConfirmButton");
    const choice = await vscode.window.showWarningMessage(
      message,
      { modal: true, detail: detailLines.join("\n\n") },
      confirmLabel,
    );
    if (choice !== confirmLabel) {
      this.creatingDevice = false;
      this.deps.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: t("deviceOps.createCancelled"),
        device: null,
      });
      return;
    }
    this.deps.post({ type: "deviceAddProgress", phase: "installing" });
    this.spawnInstallSystemImage(install.package, msg.source, (ok, error) => {
      if (!ok) {
        this.creatingDevice = false;
        this.deps.post({
          type: "createDeviceResult",
          ok: false,
          name: msg.name,
          error: error ?? t("deviceOps.installSystemImageFailedGeneric"),
          device: null,
        });
        return;
      }
      this.deps.post({ type: "deviceAddProgress", phase: "creating" });
      // creatingDevice の解除は spawnCreateDevice 側の respond(onResult 省略時)に任せる
      this.spawnCreateDevice(msg);
    });
  }

  /**
   * runCreateDevice/confirmAndSpawnCreateDevice からの実処理。finished が来る前にプロセスが
   * 落ちた場合は合成の失敗結果を送る(executeDeviceOpJob と同じパターン)。成功時は
   * FileSystemWatcher 経由でも postProfileInfo() が呼ばれるが、反映を待たせないようここでも
   * MonitorPanelDeps.notifyProjectDeviceCatalogChanged 経由で明示的に呼ぶ(冪等なので二重呼び出しは無害)。
   * msg.register が false、または source が remote のときは `--no-register` を付与し物理作成のみ
   * 行う(実行プロファイルには追記しない)。remote は register の値によらず強制する ——
   * リモート側に登録してもプロファイルの正はローカルで、次回ディスパッチの rsync --delete で
   * 消えるため(§13)。作成した1台は #device-pick-overlay の再取得→チェック→OK
   * (runProfileDevicesSync。常にローカルへ書く既存経路)にそのまま乗せてローカル登録する。
   */
  private spawnCreateDevice(msg: CreateDeviceMessage, onResult?: CreateDeviceOutcomeHandler): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      if (onResult) {
        onResult({ ok: false, error: t("deviceOps.projectUnresolved"), device: null });
        return;
      }
      this.creatingDevice = false;
      this.deps.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: t("deviceOps.projectUnresolved"),
        device: null,
      });
      return;
    }
    const apiArgs = [
      "api",
      "create-device",
      "--project",
      resolution.project,
      "--platform",
      msg.platform,
      "--name",
      msg.name,
      "--model",
      msg.model,
      "--os",
      msg.os,
    ];
    // このダイアログは常に #device-pick-overlay の「+」からしか開かず、常に register:false
    // (物理作成のみ。登録は #device-pick-overlay の OK[runProfileDevicesSync]が別途行う)。
    // `--profile` は登録するときだけ必要(CLI 契約)なので、常に --no-register のこの経路では渡さない。
    if (!msg.register || msg.source.kind === "remote") {
      apiArgs.push("--no-register");
    }
    // 上書き(既存の実体を消してから作る)。判定と確認は呼び出し側で済んでいる
    if (msg.overwrite) {
      apiArgs.push("--overwrite");
    }
    const args = deviceCommandArgs(msg.source, apiArgs);
    const source = msg.source;

    let responded = false;
    const respond = (
      ok: boolean,
      error: string | null,
      device: { avd: string | null; udid: string | null } | null,
    ): void => {
      if (responded) {
        return;
      }
      responded = true;
      const detail = error ? withSourceContext(error, source) : error;
      // **バッチのときは creatingDevice を落とさない**(1台ごとに落とすと、次の1台の
      // 多重実行ガードが素通りする)。解除はループを回している runBatchCreateDevices の責任
      if (onResult) {
        if (ok) {
          this.deps.notifyProjectDeviceCatalogChanged();
        }
        onResult({ ok, error: detail, device });
        return;
      }
      this.creatingDevice = false;
      this.deps.post({ type: "createDeviceResult", ok, name: msg.name, error: detail, device });
      if (ok) {
        this.deps.notifyProjectDeviceCatalogChanged();
      }
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.createDeviceStartFailed", { name: msg.name, error: String(error) }),
      );
      respond(false, String(error), null);
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isCreateDeviceEvent(value)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", { label: `create-device ${msg.name}`, value: JSON.stringify(value) }),
          );
          return;
        }
        if (value.kind === "log") {
          this.deps.outputChannel.appendLine(`[create-device ${msg.name}] ${value.message}`);
        } else {
          if (!value.ok) {
            this.deps.outputChannel.appendLine(
              t("deviceOps.log.createDeviceFailed", {
                name: msg.name,
                error: value.error ?? t("deviceOps.detailUnknown"),
              }),
            );
          }
          respond(value.ok, value.error, value.device ? { avd: value.device.avd, udid: value.device.udid } : null);
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[create-device ${msg.name} stdout] ${line}`),
    );
    // stderr の末尾を保持する。**finished を経由せず落ちたときはこれが唯一の手掛かり** ——
    // exit code だけ出しても「何が起きたか」は OUTPUT を開くまで分からない
    // (実害: リモートの fleetest が古く --overwrite を知らず exit 64。画面には数字しか出なかった)
    let lastStderr = "";
    const rememberStderr = (line: string): void => {
      const trimmed = line.trim();
      if (trimmed.length > 0) {
        lastStderr = trimmed;
      }
    };
    const stderrParser = new NdjsonParser(
      (value) => {
        this.deps.outputChannel.appendLine(`[create-device ${msg.name} stderr] ${JSON.stringify(value)}`);
      },
      (line) => {
        rememberStderr(line);
        this.deps.outputChannel.appendLine(`[create-device ${msg.name} stderr] ${line}`);
      },
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.createDeviceRuntimeError", { name: msg.name, error: error.message }),
      );
      respond(false, error.message, null);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.createDeviceClosed", { name: msg.name, exitCode: String(exitCode) }),
      );
      // finished を経由せず落ちた場合の合成失敗(executeDeviceOpJob と同じパターン。responded ガードで二重防止)。
      // **exit 64 = 引数エラー**(ArgumentParser)。リモートで出たなら、ほぼ「向こうの fleetest が
      // 古くてこのオプションを知らない」なので、版合わせの案内に変える(数字だけでは辿れない)
      const detail = lastStderr.length > 0 ? `${t("deviceOps.processExitedWithCode", { exitCode: String(exitCode) })}: ${lastStderr}` : t("deviceOps.processExitedWithCode", { exitCode: String(exitCode) });
      const staleRemote = exitCode === 64 && source.kind === "remote";
      respond(false, staleRemote ? t("deviceOps.remoteCliTooOld", { machine: source.machine, detail: lastStderr }) : detail, null);
    });
  }

  /**
   * `fleetest api install-system-image --package <pkg> --accept-licenses` を実行する
   * (confirmAndInstallThenCreate/runBatchCreateDevices からの実処理)。ダウンロードは数分かかりうる
   * ため timeout は設けない(runInstallCmdlineTools と同じ方針)。作成物を持たないコマンドなので
   * spawnCreateDevice と違い device は返さない —— 結果は (ok, error) だけの callback で渡す。
   */
  private spawnInstallSystemImage(
    pkg: string,
    source: DeviceCommandSource,
    onResult: (ok: boolean, error: string | null) => void,
  ): void {
    const config = this.deps.getConfig();
    const args = deviceCommandArgs(source, installSystemImageApiArgs(pkg));

    let responded = false;
    const respond = (ok: boolean, error: string | null): void => {
      if (responded) {
        return;
      }
      responded = true;
      onResult(ok, error ? withSourceContext(error, source) : error);
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.installSystemImageStartFailed", { package: pkg, error: String(error) }),
      );
      respond(false, String(error));
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isInstallSystemImageEvent(value)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", { label: `install-system-image ${pkg}`, value: JSON.stringify(value) }),
          );
          return;
        }
        if (value.kind === "log") {
          this.deps.outputChannel.appendLine(`[install-system-image ${pkg}] ${value.message}`);
        } else {
          if (!value.ok) {
            this.deps.outputChannel.appendLine(
              t("deviceOps.log.installSystemImageFailed", {
                package: pkg,
                error: value.error ?? t("deviceOps.detailUnknown"),
              }),
            );
          }
          respond(value.ok, value.error);
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[install-system-image ${pkg} stdout] ${line}`),
    );
    // finished を経由せず落ちた場合の唯一の手掛かり(spawnCreateDevice の lastStderr と同じ理由)。
    let lastStderr = "";
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[install-system-image ${pkg} stderr] ${JSON.stringify(value)}`),
      (line) => {
        const trimmed = line.trim();
        if (trimmed.length > 0) {
          lastStderr = trimmed;
        }
        this.deps.outputChannel.appendLine(`[install-system-image ${pkg} stderr] ${line}`);
      },
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.installSystemImageRuntimeError", { package: pkg, error: error.message }),
      );
      respond(false, error.message);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.installSystemImageClosed", { package: pkg, exitCode: String(exitCode) }),
      );
      const detail = lastStderr.length > 0
        ? `${t("deviceOps.processExitedWithCode", { exitCode: String(exitCode) })}: ${lastStderr}`
        : t("deviceOps.processExitedWithCode", { exitCode: String(exitCode) });
      respond(false, detail);
    });
  }

  /** 破壊的操作の modal に添える1行。**machine の null は手元**(控えの鍵は `LOCAL_MACHINE_KEY`)——
   * 手元の run も dispatch.lock を取るので、リモートと同じ規則で添える。 */
  private occupancyDetail(machine: string | null): string | undefined {
    return occupancyDetailLine(machine, this.deps.machineLock(machine ?? LOCAL_MACHINE_KEY));
  }

  /**
   * #device-pick-overlay の行右クリック「削除」: `fleetest api delete-device` を実行し、ホスト上の
   * 実体(シミュレータ/AVD)を消す(runProfileDeviceRemove のプロファイル除去とは別物。本体は残さない)。
   * 破壊的・不可逆な操作なので、ローカル/リモートどちらでも必ずホスト側 modal 確認を挟む
   * (§13・runCreateDevice のリモート確認と同じ showWarningMessage({modal:true}) 方式だが、
   * こちらは常に確認する — create と違い「作るだけ」ではなく実体を消すため)。
   */
  async runDeleteDevice(msg: DevicePickDeviceDeleteMessage): Promise<void> {
    if (this.deletingIdentifiers.has(msg.identifier)) {
      this.deps.post({
        type: "devicePickDeviceDeleteResult",
        ok: false,
        identifier: msg.identifier,
        name: msg.name,
        error: t("deviceOps.deleteAlreadyRunning"),
        referencedBy: [],
      });
      return;
    }
    this.deletingIdentifiers.add(msg.identifier);
    const machineLabel = msg.source.kind === "remote" ? msg.source.machine : t("deviceOps.machineLocalLabel");
    const deleteLabel = t("deviceOps.deleteConfirmButton");
    const choice = await vscode.window.showWarningMessage(
      t("deviceOps.deleteConfirmMessage", { name: msg.name, machine: machineLabel }),
      // **手元も添える** —— 手元の run も dispatch.lock を取るので、占有は機械を問わず同じ規則
      { modal: true, detail: this.occupancyDetail(msg.source.kind === "remote" ? msg.source.machine : null) },
      deleteLabel,
    );
    if (choice !== deleteLabel) {
      this.deletingIdentifiers.delete(msg.identifier);
      this.deps.post({
        type: "devicePickDeviceDeleteResult",
        ok: false,
        identifier: msg.identifier,
        name: msg.name,
        error: t("deviceOps.deleteCancelled"),
        referencedBy: [],
      });
      return;
    }
    this.spawnDeleteDevice(msg);
  }

  /**
   * runDeleteDevice からの実処理(confirm 済み)。finished が来る前にプロセスが落ちた場合は合成の
   * 失敗結果を送る(spawnCreateDevice と同じパターン)。成功時、referencedBy が非空なら
   * (削除した実体をまだ参照している実行プロファイルが残る)webview のダイアログが閉じていても
   * 気付けるよう、別途 warning 通知も出す(devicePickDeviceDeleteResult はダイアログが開いている
   * 間しか見えないため)。
   */
  private spawnDeleteDevice(msg: DevicePickDeviceDeleteMessage): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    const project = resolution.kind === "resolved" ? resolution.project : undefined;
    const args = deviceCommandArgs(msg.source, deleteDeviceApiArgs(msg.platform, msg.identifier, project));
    const source = msg.source;

    let responded = false;
    const respond = (ok: boolean, error: string | null, referencedBy: readonly string[]): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.deletingIdentifiers.delete(msg.identifier);
      const finalError = error ? withSourceContext(error, source) : error;
      this.deps.post({
        type: "devicePickDeviceDeleteResult",
        ok,
        identifier: msg.identifier,
        name: msg.name,
        error: finalError,
        referencedBy,
      });
      if (ok) {
        this.deps.outputChannel.appendLine(t("deviceOps.log.deleteDeviceSucceeded", { name: msg.name }));
        // **実体が消えたら登録も外す**(2026-08-25 の報告)。「デバイスを選択」の OK 側の同期
        // (runProfileDevicesSync)に任せると、**キャンセルしたときに実体の無い登録が残る**。
        // 消えた事実にプロファイルを合わせるだけなので確認は聞かない(削除自体は確認済み)。
        // 引き当ては (platform, machine, name) —— 別の機械の同名を巻き添えにしない。
        // **referencedBy が空でも呼ぶ** —— こちらは全実行プロファイルを自分で全件走査する
        {
          const machine = source.kind === "remote" ? source.machine : undefined;
          const updated = this.deps.unregisterDeletedDevice(msg.platform, msg.name, machine);
          if (updated.runs.length > 0) {
            this.deps.outputChannel.appendLine(
              t("deviceOps.log.deleteDeviceUnregistered", {
                name: msg.name,
                profiles: updated.runs.join(t("deviceOps.nameSeparator")),
              }),
            );
          }
          // 外せなかったぶんだけ従来どおり警告する(形式不正・読めない等)
          const remaining = referencedBy.filter((run) => !updated.runs.includes(run));
          if (remaining.length > 0) {
            void vscode.window.showWarningMessage(
              t("deviceOps.deleteReferencedByWarning", {
                name: msg.name,
                profiles: remaining.join(t("deviceOps.nameSeparator")),
              }),
            );
          }
        }
      } else {
        this.deps.outputChannel.appendLine(
          t("deviceOps.log.deleteDeviceFailed", { name: msg.name, error: finalError ?? "" }),
        );
        void vscode.window.showErrorMessage(`fleetest: ${finalError ?? t("deviceOps.deleteFailedGeneric")}`);
      }
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.deleteDeviceStartFailed", { name: msg.name, error: String(error) }),
      );
      respond(false, String(error), []);
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDeleteDeviceEvent(value)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", { label: `delete-device ${msg.name}`, value: JSON.stringify(value) }),
          );
          return;
        }
        if (value.kind === "log") {
          this.deps.outputChannel.appendLine(`[delete-device ${msg.name}] ${value.message}`);
        } else {
          respond(value.ok, value.error, value.referencedBy ?? []);
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[delete-device ${msg.name} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[delete-device ${msg.name} stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[delete-device ${msg.name} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.deleteDeviceRuntimeError", { name: msg.name, error: error.message }),
      );
      respond(false, error.message, []);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.deleteDeviceClosed", { name: msg.name, exitCode: String(exitCode) }),
      );
      // finished を経由せず落ちた場合の合成失敗(spawnCreateDevice と同じパターン。responded ガードで二重防止)。
      respond(false, t("deviceOps.processExitedWithCode", { exitCode: String(exitCode) }), []);
    });
  }
}
