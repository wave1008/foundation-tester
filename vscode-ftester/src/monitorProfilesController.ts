// monitorProfilesController.ts
// デバイスモニターパネル(monitorPanel.ts)の「プロファイル」タブ関連ロジック。
// モニター再起動判定・デバイスライフサイクルキューへの投入は monitorPanel.ts が仲介するため、
// このクラスから直接呼ばない(サブコントローラ間の直接参照禁止)。

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  listAppProfileNames,
  listMachineProfiles,
  listRunProfileNames,
  type MachineProfileSummary,
  readLocalMachineName,
  readMachineDeviceNames,
  resolveProjectName,
  updateLocalMachineName,
} from "./config";
import {
  type AppProfileFormFields,
  buildRunProfileTemplate,
  machineDeviceDetail,
  type MonitorFromWebviewMessage,
  parseAppProfileForForm,
  parseRunProfileForForm,
  removeDeviceFromMachineProfile,
  syncDevicesInMachineProfile,
  type RunProfileFormFields,
  updateAppProfileInObject,
  updateDeviceInMachineProfile,
  updateRunProfileInObject,
  validateNewAppProfileName,
  validateNewMachineProfileName,
  validateNewRunProfileName,
} from "./monitorModel";
import { summarizeDeviceNames } from "./monitorDeviceOps";
import type { MonitorPanelDeps } from "./monitorPanel";

type MachineDeviceUpdateMessage = Extract<MonitorFromWebviewMessage, { type: "machineDeviceUpdate" }>;
type MachineDevicesSyncMessage = Extract<MonitorFromWebviewMessage, { type: "machineDevicesSync" }>;
type RunProfileSaveMessage = Extract<MonitorFromWebviewMessage, { type: "runProfileSave" }>;
type AppProfileSaveMessage = Extract<MonitorFromWebviewMessage, { type: "appProfileSave" }>;

/**
 * 「プロファイル」タブ(実行/アプリ/マシンプロファイル)のCRUD・フォーム・名前入力モーダルを担う。
 * モニター再起動の要否判定は monitorPanel.ts 側が行う。
 */
export class MonitorProfilesController {
  /**
   * profiles/runs/*.json の作成・削除・変更を監視する。作成・削除は postProfileInfo() で
   * ドロップダウンを最新化する(手動削除や他ツールでの追加も反映するため)。変更(Change)は
   * 一覧・選択名に影響しないため postProfileInfo() は呼ばず、編集対象と同名であれば
   * runProfileFileChanged を送って外部編集をフォームへ反映させる(編集中かの判定は webview 側)。
   */
  private readonly profileFileWatcher: vscode.FileSystemWatcher;
  /**
   * profiles/machines/*.json を監視し、マシンプロファイル一覧を最新化する。profileFileWatcher と
   * 異なり Change も購読する — デバイス追記(create-device 成功後や手動編集)が既存ファイルの
   * 内容変更として届くため。
   */
  private readonly machineFileWatcher: vscode.FileSystemWatcher;
  /**
   * profiles/apps/*.json を監視する(profileFileWatcher と同方針)。作成・削除は postProfileInfo()、
   * 変更は編集対象と同名であれば appProfileFileChanged を送り外部編集を反映させる。
   */
  private readonly appsFileWatcher: vscode.FileSystemWatcher;
  /**
   * 名前入力モーダル(#name-input-overlay)の応答待ち状態。promptName() 呼び出しごとに id を払い出し、
   * webview からの nameInputConfirm/Cancel の id と突き合わせて resolve する。
   */
  private pendingNameInput: { id: number; resolve: (value: string | undefined) => void } | undefined;
  /** promptName() 呼び出しごとに採番するID(nameInputConfirm/Cancel との対応付け)。 */
  private nameInputSeq = 0;

  constructor(private readonly deps: MonitorPanelDeps) {
    this.profileFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(deps.workspaceRoot, "Projects/*/profiles/runs/*.json"),
    );
    this.profileFileWatcher.onDidCreate(() => this.postProfileInfo());
    this.profileFileWatcher.onDidDelete(() => this.postProfileInfo());
    this.profileFileWatcher.onDidChange((uri) => {
      this.deps.post({ type: "runProfileFileChanged", name: path.basename(uri.fsPath, ".json") });
    });
    this.machineFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(deps.workspaceRoot, "Projects/*/profiles/machines/*.json"),
    );
    this.machineFileWatcher.onDidCreate(() => this.postMachineProfileInfo());
    this.machineFileWatcher.onDidDelete(() => this.postMachineProfileInfo());
    this.machineFileWatcher.onDidChange(() => this.postMachineProfileInfo());
    this.appsFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(deps.workspaceRoot, "Projects/*/profiles/apps/*.json"),
    );
    this.appsFileWatcher.onDidCreate(() => this.postProfileInfo());
    this.appsFileWatcher.onDidDelete(() => this.postProfileInfo());
    this.appsFileWatcher.onDidChange((uri) => {
      this.deps.post({ type: "appProfileFileChanged", name: path.basename(uri.fsPath, ".json") });
    });
  }

  /** dispose() から呼ばれる: 名前入力待ちの Promise が残っていればキャンセル扱いで解決する。 */
  disposePendingNameInput(): void {
    if (this.pendingNameInput) {
      const resolve = this.pendingNameInput.resolve;
      this.pendingNameInput = undefined;
      resolve(undefined);
    }
  }

  /** dispose() から呼ばれる: プロファイル関連のファイルウォッチャーを破棄する。 */
  disposeWatchers(): void {
    this.profileFileWatcher.dispose();
    this.machineFileWatcher.dispose();
    this.appsFileWatcher.dispose();
  }

  /**
   * 実行プロファイル選択ドロップダウン(一覧+現在値)を webview へ送る。対象プロジェクトが
   * 解決できない場合は一覧のみ空にする(current は設定の生値をそのまま送る)。
   * apps(アプリプロファイル名一覧)は実行プロファイル設定フォームのアプリ選択が使う。
   */
  postProfileInfo(): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    const profiles =
      resolution.kind === "resolved" ? listRunProfileNames(this.deps.workspaceRoot, resolution.project) : [];
    const apps =
      resolution.kind === "resolved" ? listAppProfileNames(this.deps.workspaceRoot, resolution.project) : [];
    this.deps.post({ type: "profileInfo", profiles, current: config.profile, apps });
  }

  /**
   * 現在使うべきマシンプロファイル名を決める(postMachineProfileInfo・handleProfileAdd 共通)。
   * readLocalMachineName() の値が summaries に存在すればそれを、無ければ summaries が1件のときに
   * 限り採用する(あいまいな場合は選ばない。readMachineDeviceNames と同じ方針 — 変更時は両方揃える)。
   */
  private resolveCurrentMachineName(summaries: readonly MachineProfileSummary[]): string | null {
    const machineName = readLocalMachineName();
    if (machineName !== null && summaries.some((summary) => summary.name === machineName)) {
      return machineName;
    }
    return summaries.length === 1 ? summaries[0]!.name : null;
  }

  /**
   * マシンプロファイル一覧(+現在のマシン)を webview へ送る。対象プロジェクトが解決できない場合は
   * machines を空にしエラーメッセージを添える(webview はエラー表示に切り替える)。
   * 現在のマシンの決定は resolveCurrentMachineName を参照。
   */
  postMachineProfileInfo(): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.deps.post({
        type: "machineProfileInfo",
        machines: [],
        current: null,
        error: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      });
      return;
    }
    const summaries = listMachineProfiles(this.deps.workspaceRoot, resolution.project);
    const current = this.resolveCurrentMachineName(summaries);
    const machines = summaries.map((summary) => ({
      name: summary.name,
      devices: summary.devices.map((device) => ({
        name: device.name,
        platform: device.platform,
        detail: machineDeviceDetail(device),
        // 右ペインの編集フォーム用の生フィールド。undefined は postMessage の JSON化で
        // 自然に省略される。
        simulator: device.simulator,
        os: device.os,
        udid: device.udid,
        port: device.port,
        avd: device.avd,
      })),
    }));
    this.deps.post({ type: "machineProfileInfo", machines, current, error: null });
  }

  /**
   * 名前入力モーダルを開き、確定/キャンセルされるまで待つ。showInputBox と同じ契約
   * (キャンセル時 undefined、確定時は未trimの入力文字列)。名前検証は webview 側で行うが、
   * 呼び出し側は confirm 後に trim して各自の validateNewXxxName で再検証する。
   */
  private promptName(options: {
    readonly title: string;
    readonly value: string;
    readonly noun: string;
    readonly dupLabel: string;
    readonly existing: readonly string[];
    readonly caseInsensitiveDup: boolean;
  }): Promise<string | undefined> {
    // 多重オープンの防御: 既に応答待ちがあれば、上書きする前にキャンセル扱いで解決しておく。
    if (this.pendingNameInput) {
      const previous = this.pendingNameInput;
      this.pendingNameInput = undefined;
      previous.resolve(undefined);
    }
    this.nameInputSeq += 1;
    const id = this.nameInputSeq;
    return new Promise((resolve) => {
      this.pendingNameInput = { id, resolve };
      this.deps.post({
        type: "nameInputOpen",
        id,
        title: options.title,
        value: options.value,
        noun: options.noun,
        dupLabel: options.dupLabel,
        existing: options.existing,
        caseInsensitiveDup: options.caseInsensitiveDup,
      });
    });
  }

  /** webview からの "nameInputConfirm"(promptName の確定)応答。handleWebviewMessage から委譲される。 */
  resolveNameInput(id: number, name: string): void {
    if (this.pendingNameInput && this.pendingNameInput.id === id) {
      const resolve = this.pendingNameInput.resolve;
      this.pendingNameInput = undefined;
      resolve(name);
    }
  }

  /** webview からの "nameInputCancel"(promptName のキャンセル)応答。handleWebviewMessage から委譲される。 */
  cancelNameInput(id: number): void {
    if (this.pendingNameInput && this.pendingNameInput.id === id) {
      const resolve = this.pendingNameInput.resolve;
      this.pendingNameInput = undefined;
      resolve(undefined);
    }
  }

  /**
   * webview のドロップダウン操作を ftester.profile 設定へ反映する。成功時は
   * onDidChangeConfiguration 経由で postProfileInfo() が呼ばれるため、ここから直接 post しない。
   */
  selectProfile(profile: string): void {
    const NONE_LABEL = "(プロファイルなし)";
    const displayValue = profile === "" ? NONE_LABEL : profile;
    vscode.workspace
      .getConfiguration("ftester")
      .update("profile", profile, vscode.ConfigurationTarget.Workspace)
      .then(
        () => {
          this.deps.outputChannel.appendLine(`[ftester] 実行プロファイルを「${displayValue}」に設定しました。`);
        },
        (error: unknown) => {
          this.deps.outputChannel.appendLine(
            `[ftester] 実行プロファイルの設定に失敗しました(${displayValue}): ${String(error)}`,
          );
        },
      );
  }

  // ---- 実行プロファイルの追加/コピー/名前変更/削除(プロファイルタブ下半分のアイコンボタン) ------
  // ftester.profile 設定(selectProfile)には触れない(名前変更で対象を指していた場合の追随を除く。
  // handleProfileRename 参照)。

  /** Projects/<project>/profiles/runs ディレクトリの絶対パス。 */
  private runsDir(project: string): string {
    return path.join(this.deps.workspaceRoot, "Projects", project, "profiles", "runs");
  }

  /** 対象プロジェクトが解決できない場合は警告して undefined を返す(呼び出し側はここで中断)。 */
  private resolveProjectOrWarn(): string | undefined {
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      void vscode.window.showWarningMessage(
        "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      );
      return undefined;
    }
    return resolution.project;
  }

  /** 「+」ボタン: 新しいプロファイル名を入力させ、テンプレート内容で作成して編集対象に選択する。 */
  async handleProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listRunProfileNames(this.deps.workspaceRoot, project);
    const input = await this.promptName({
      title: "新しい実行プロファイル名",
      value: "",
      noun: "プロファイル名",
      dupLabel: "実行プロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return;
    }
    const name = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewRunProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    const runsDir = this.runsDir(project);
    try {
      fs.mkdirSync(runsDir, { recursive: true });
      const machine = this.resolveCurrentMachineName(listMachineProfiles(this.deps.workspaceRoot, project)) ?? "";
      const template = buildRunProfileTemplate(
        machine,
        listAppProfileNames(this.deps.workspaceRoot, project),
        readMachineDeviceNames(this.deps.workspaceRoot, project),
      );
      fs.writeFileSync(path.join(runsDir, `${name}.json`), template, "utf8");
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を追加しました。`);
      this.postProfileInfo();
      this.deps.post({ type: "runProfileSelected", name });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」の追加に失敗しました。`);
    }
  }

  /** 「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製し、複製先を編集対象に選択する。 */
  async handleProfileCopy(source: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const runsDir = this.runsDir(project);
    const sourcePath = path.join(runsDir, `${source}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: 実行プロファイル「${source}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    const existing = listRunProfileNames(this.deps.workspaceRoot, project);
    const input = await this.promptName({
      title: `「${source}」のコピー先の実行プロファイル名`,
      value: `${source}-copy`,
      noun: "プロファイル名",
      dupLabel: "実行プロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return;
    }
    const name = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewRunProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    try {
      const content = fs.readFileSync(sourcePath, "utf8");
      fs.mkdirSync(runsDir, { recursive: true });
      fs.writeFileSync(path.join(runsDir, `${name}.json`), content, "utf8");
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${source}」を「${name}」としてコピーしました。`);
      this.postProfileInfo();
      this.deps.post({ type: "runProfileSelected", name });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」のコピーに失敗しました。`);
    }
  }

  /**
   * 「削除」ボタン: モーダル確認で「削除」が選ばれたときのみ削除する。削除対象が現在選択中の
   * プロファイル(ftester.profile)であれば selectProfile("") で戻す(新スコープが null になると
   * devicesToShutdownOnScopeChange は常に空を返すため、この切り替えによる自動シャットダウンは
   * 発生しない)。
   */
  async handleProfileDelete(name: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `実行プロファイル「${name}」を削除しますか?この操作は元に戻せません。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.runsDir(project), `${name}.json`));
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を削除しました。`);
      if (this.deps.getConfig().profile === name) {
        this.selectProfile("");
      }
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」の削除に失敗しました。`);
    }
    this.postProfileInfo();
  }

  /**
   * 「✏」ボタン: runs/<name>.json をリネームする。ftester.profile が旧名を指していた場合は
   * selectProfile(新名) で追随させる(しないとアクティブなプロファイルの解決が壊れる)。
   */
  async handleProfileRename(profile: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const runsDir = this.runsDir(project);
    const oldPath = path.join(runsDir, `${profile}.json`);
    if (!fs.existsSync(oldPath)) {
      void vscode.window.showWarningMessage(`ftester: 実行プロファイル「${profile}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    // 重複チェックは自分自身(現在の名前)を除いた一覧に対して行う
    // (含めると「変更なし」のリネームも常に重複エラーになるため)。
    const existing = listRunProfileNames(this.deps.workspaceRoot, project).filter((name) => name !== profile);
    const input = await this.promptName({
      title: `「${profile}」の新しい実行プロファイル名`,
      value: profile,
      noun: "プロファイル名",
      dupLabel: "実行プロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return;
    }
    const newName = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewRunProfileName(newName, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    if (newName === profile) {
      return;
    }
    try {
      fs.renameSync(oldPath, path.join(runsDir, `${newName}.json`));
      if (this.deps.getConfig().profile === profile) {
        this.selectProfile(newName);
      }
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」を「${newName}」に変更しました。`);
      this.postProfileInfo();
      this.deps.post({ type: "runProfileSelected", name: newName });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] 実行プロファイル「${profile}」の名前変更に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${profile}」の名前変更に失敗しました。`);
    }
  }

  // ---- アプリプロファイルの追加/コピー/名前変更/削除(プロファイルタブ中段のアイコンボタン) --------
  // ftester.* から直接参照されないため selectProfile 相当の追随は無い(壊れた参照の検出は
  // CLI 側の validate-profile に委ねる)。

  /** Projects/<project>/profiles/apps ディレクトリの絶対パス。 */
  private appsDir(project: string): string {
    return path.join(this.deps.workspaceRoot, "Projects", project, "profiles", "apps");
  }

  /** 「+」ボタン: 新しいアプリプロファイル名を入力させ、テンプレート内容で作成して編集対象に選択する。 */
  async handleAppProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listAppProfileNames(this.deps.workspaceRoot, project);
    const input = await this.promptName({
      title: "新しいアプリプロファイル名",
      value: "",
      noun: "アプリプロファイル名",
      dupLabel: "アプリプロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return;
    }
    const name = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewAppProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    const appsDir = this.appsDir(project);
    try {
      fs.mkdirSync(appsDir, { recursive: true });
      // テンプレートは appName のみ(埋めるべき候補一覧が無く buildRunProfileTemplate とは異なる)。
      const template = { android: {}, common: { appName: name }, ios: {} };
      fs.writeFileSync(path.join(appsDir, `${name}.json`), `${JSON.stringify(template, null, 2)}\n`, "utf8");
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」を追加しました。`);
      this.postProfileInfo();
      this.deps.post({ type: "appProfileSelected", name });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${name}」の追加に失敗しました。`);
    }
  }

  /** 「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製し、複製先を編集対象に選択する。 */
  async handleAppProfileCopy(source: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const appsDir = this.appsDir(project);
    const sourcePath = path.join(appsDir, `${source}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: アプリプロファイル「${source}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    const existing = listAppProfileNames(this.deps.workspaceRoot, project);
    const input = await this.promptName({
      title: `「${source}」のコピー先のアプリプロファイル名`,
      value: `${source}-copy`,
      noun: "アプリプロファイル名",
      dupLabel: "アプリプロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return;
    }
    const name = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewAppProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    try {
      const content = fs.readFileSync(sourcePath, "utf8");
      fs.mkdirSync(appsDir, { recursive: true });
      fs.writeFileSync(path.join(appsDir, `${name}.json`), content, "utf8");
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${source}」を「${name}」としてコピーしました。`);
      this.postProfileInfo();
      this.deps.post({ type: "appProfileSelected", name });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${name}」のコピーに失敗しました。`);
    }
  }

  /** 「削除」ボタン: モーダル確認で「削除」が選ばれたときのみ削除する(ftester.* 設定への追従は不要)。 */
  async handleAppProfileDelete(name: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `アプリプロファイル「${name}」を削除しますか?この操作は元に戻せません。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.appsDir(project), `${name}.json`));
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」を削除しました。`);
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${name}」の削除に失敗しました。`);
    }
    this.postProfileInfo();
  }

  /**
   * 「✏」ボタン: apps/<name>.json をリネームする。実行プロファイルの app フィールドが旧名を
   * 指していても追随しない(壊れた参照は CLI 側の validate-profile が検出する)。
   */
  async handleAppProfileRename(profile: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const appsDir = this.appsDir(project);
    const oldPath = path.join(appsDir, `${profile}.json`);
    if (!fs.existsSync(oldPath)) {
      void vscode.window.showWarningMessage(`ftester: アプリプロファイル「${profile}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    // 重複チェックは自分自身(現在の名前)を除いた一覧に対して行う(handleProfileRename と同じ方針)。
    const existing = listAppProfileNames(this.deps.workspaceRoot, project).filter((name) => name !== profile);
    const input = await this.promptName({
      title: `「${profile}」の新しいアプリプロファイル名`,
      value: profile,
      noun: "アプリプロファイル名",
      dupLabel: "アプリプロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return;
    }
    const newName = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewAppProfileName(newName, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    if (newName === profile) {
      return;
    }
    try {
      fs.renameSync(oldPath, path.join(appsDir, `${newName}.json`));
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」を「${newName}」に変更しました。`);
      this.postProfileInfo();
      this.deps.post({ type: "appProfileSelected", name: newName });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] アプリプロファイル「${profile}」の名前変更に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${profile}」の名前変更に失敗しました。`);
    }
  }

  /** Projects/<project>/profiles/machines ディレクトリの絶対パス。 */
  private machinesDir(project: string): string {
    return path.join(this.deps.workspaceRoot, "Projects", project, "profiles", "machines");
  }

  // ---- マシンプロファイル自体の追加/削除/名前変更(マシン名横の [+][−][✏] ボタン) -----------------
  // 追加/名前変更の直後は machineProfileSelected で選択を新プロファイルへ移す
  // (削除後の選択の付け替えは webview 側の既存フォールバックに任せるので送らない)。

  /** マシン名横「+」ボタン: 新しい名前を入力させ、空のスケルトンで machines/<name>.json を作る。 */
  async handleMachineProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listMachineProfiles(this.deps.workspaceRoot, project).map((summary) => summary.name);
    const input = await this.promptName({
      title: "新しいマシンプロファイル名",
      value: "",
      noun: "マシンプロファイル名",
      dupLabel: "マシンプロファイル",
      existing,
      caseInsensitiveDup: true,
    });
    if (input === undefined) {
      return;
    }
    const name = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewMachineProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    const machinesDir = this.machinesDir(project);
    try {
      fs.mkdirSync(machinesDir, { recursive: true });
      const skeleton = { android: { devices: [] }, ios: { devices: [] } };
      fs.writeFileSync(path.join(machinesDir, `${name}.json`), `${JSON.stringify(skeleton, null, 2)}\n`, "utf8");
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${name}」を追加しました。`);
      this.postMachineProfileInfo();
      this.deps.post({ type: "machineProfileSelected", name });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${name}」の追加に失敗しました。`);
    }
  }

  /** マシン名横「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製し、選択状態にする。 */
  async handleMachineProfileCopy(machine: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const machinesDir = this.machinesDir(project);
    const sourcePath = path.join(machinesDir, `${machine}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」が見つかりません。`);
      this.postMachineProfileInfo();
      return;
    }
    const existing = listMachineProfiles(this.deps.workspaceRoot, project).map((summary) => summary.name);
    const input = await this.promptName({
      title: `「${machine}」のコピー先のマシンプロファイル名`,
      value: `${machine}-copy`,
      noun: "マシンプロファイル名",
      dupLabel: "マシンプロファイル",
      existing,
      caseInsensitiveDup: true,
    });
    if (input === undefined) {
      return;
    }
    const name = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewMachineProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    try {
      fs.copyFileSync(sourcePath, path.join(machinesDir, `${name}.json`));
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」を「${name}」としてコピーしました。`);
      this.postMachineProfileInfo();
      this.deps.post({ type: "machineProfileSelected", name });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${name}」のコピーに失敗しました。`);
    }
  }

  /**
   * マシン名横「✏」ボタン: machines/<machine>.json をリネームする。CLI 側の登録名
   * (`ftester machine set` が書く ~/.config/ftester/config.json の machineName)が旧名と一致していれば
   * 追随して書き換える(一致させないと postMachineProfileInfo の current 決定が崩れる)。
   */
  async handleMachineProfileRename(machine: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const machinesDir = this.machinesDir(project);
    const oldPath = path.join(machinesDir, `${machine}.json`);
    if (!fs.existsSync(oldPath)) {
      void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」が見つかりません。`);
      this.postMachineProfileInfo();
      return;
    }
    // 重複チェックは自分自身を除いた一覧に対して行う(handleProfileRename と同じ方針)。
    const existing = listMachineProfiles(this.deps.workspaceRoot, project)
      .map((summary) => summary.name)
      .filter((name) => name !== machine);
    const input = await this.promptName({
      title: `「${machine}」の新しいマシンプロファイル名`,
      value: machine,
      noun: "マシンプロファイル名",
      dupLabel: "マシンプロファイル",
      existing,
      caseInsensitiveDup: true,
    });
    if (input === undefined) {
      return;
    }
    const newName = input.trim();
    // webview側検証をすり抜けた場合の防御的な再検証。
    const nameError = validateNewMachineProfileName(newName, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    if (newName === machine) {
      return;
    }
    try {
      fs.renameSync(oldPath, path.join(machinesDir, `${newName}.json`));
      if (updateLocalMachineName(machine, newName)) {
        this.deps.outputChannel.appendLine(`[ftester] 登録マシン名(machine set)も「${newName}」に更新しました。`);
      }
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」を「${newName}」に変更しました。`);
      this.postMachineProfileInfo();
      this.deps.post({ type: "machineProfileSelected", name: newName });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${machine}」の名前変更に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${machine}」の名前変更に失敗しました。`);
    }
  }

  /**
   * マシン名横「−」ボタン: モーダル確認の上、machines/<machine>.json を削除する
   * (シミュレータ/AVD 本体は操作しない)。選択の付け替えは webview 側の既存フォールバックに
   * 任せるので、ここから machineProfileSelected は送らない。
   */
  async handleMachineProfileDelete(machine: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `マシンプロファイル「${machine}」を削除しますか?この操作は元に戻せません(プロファイルファイルのみ削除され、シミュレータ/AVD 本体は削除されません)。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.machinesDir(project), `${machine}.json`));
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」を削除しました。`);
      this.postMachineProfileInfo();
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${machine}」の削除に失敗しました。`);
    }
  }

  /**
   * デバイス行右クリック「除去」: machines/<machine>.json から names に一致するデバイスを
   * プロファイル上だけ取り除く(シミュレータ/AVD 本体は操作しない)。ユーザー可視文言は
   * この操作に限り「削除」ではなく「除去」を使う(仮想マシン本体を消す「削除」と紛らわしいため)。
   * removeDeviceFromMachineProfile を names へ順次適用し1回の書き戻しにまとめる。1件も除去
   * できなければ書き戻さない。
   */
  async handleMachineDeviceRemove(machine: string, names: readonly string[]): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const confirmMessage =
      names.length === 1
        ? `マシンプロファイル「${machine}」からデバイス「${names[0]}」を除去しますか?プロファイルからの除去のみで、シミュレータ/AVD 本体は削除されません。`
        : `マシンプロファイル「${machine}」から${names.length}台のデバイス(${summarizeDeviceNames(names)})を除去しますか?プロファイルからの除去のみで、シミュレータ/AVD 本体は削除されません。`;
    const choice = await vscode.window.showWarningMessage(confirmMessage, { modal: true }, "除去");
    if (choice !== "除去") {
      return;
    }
    const machinePath = path.join(this.machinesDir(project), `${machine}.json`);
    try {
      let parsed: unknown;
      try {
        parsed = JSON.parse(fs.readFileSync(machinePath, "utf8"));
      } catch (error) {
        this.deps.outputChannel.appendLine(
          `[ftester] マシンプロファイル「${machine}」の読み込みに失敗しました: ${String(error)}`,
        );
        void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」を読み込めませんでした。`);
        return;
      }
      let current: unknown = parsed;
      let removedCount = 0;
      for (const name of names) {
        const result = removeDeviceFromMachineProfile(current, name);
        if (!result) {
          this.deps.outputChannel.appendLine(
            `[ftester] マシンプロファイル「${machine}」の形式が不正なため、デバイスの除去を中断しました。`,
          );
          void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」を読み込めませんでした。`);
          return;
        }
        current = result.object;
        if (result.removed) {
          removedCount += 1;
        }
      }
      if (removedCount === 0) {
        this.deps.outputChannel.appendLine(
          `[ftester] マシンプロファイル「${machine}」に指定のデバイスが見つからず、除去できませんでした。`,
        );
        void vscode.window.showWarningMessage(
          `ftester: マシンプロファイル「${machine}」に指定のデバイスが見つかりませんでした。`,
        );
        return;
      }
      fs.writeFileSync(machinePath, `${JSON.stringify(current, null, 2)}\n`, "utf8");
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${machine}」から${removedCount}台のデバイスを除去しました(${names.join("、")})。`,
      );
      // FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
      // 反映を待たせないようここでも明示的に呼ぶ(冪等)。
      this.postMachineProfileInfo();
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${machine}」からのデバイス除去に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${machine}」からのデバイス除去に失敗しました。`);
    }
  }

  /**
   * 右ペイン編集フォーム「確定」: machines/<machine>.json の対象デバイスを更新する。フォームが
   * クライアント側検証済みのため確認ダイアログは無く、結果は machineDeviceUpdateResult で即返す。
   * プロジェクト未解決時もフォームのエラー表示に載せたいため resolveProjectName を直接呼ぶ
   * (resolveProjectOrWarn の vscode.window 警告は使わない)。
   */
  handleMachineDeviceUpdate(message: MachineDeviceUpdateMessage): void {
    const sendResult = (ok: boolean, name: string, error: string | null) => {
      this.deps.post({ type: "machineDeviceUpdateResult", ok, name, error });
    };

    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(
        false,
        message.originalName,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      );
      return;
    }

    const machinePath = path.join(this.machinesDir(resolution.project), `${message.machine}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(machinePath, "utf8"));
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」の読み込みに失敗しました: ${String(error)}`,
      );
      sendResult(false, message.originalName, `マシンプロファイル「${message.machine}」を読み込めませんでした。`);
      return;
    }

    const result = updateDeviceInMachineProfile(parsed, message.platform, message.originalName, message.fields);
    if (!result.ok) {
      sendResult(false, message.originalName, result.error);
      return;
    }

    try {
      fs.writeFileSync(machinePath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」のデバイス「${message.originalName}」の更新に失敗しました: ${String(error)}`,
      );
      sendResult(false, message.originalName, `マシンプロファイル「${message.machine}」への書き込みに失敗しました。`);
      return;
    }

    this.deps.outputChannel.appendLine(
      `[ftester] マシンプロファイル「${message.machine}」のデバイス「${message.originalName}」を更新しました。`,
    );
    sendResult(true, result.name, null);
    // FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
    // handleMachineDeviceRemove と同じく反映を待たせないようここでも明示的に呼ぶ(冪等)。
    this.postMachineProfileInfo();
  }

  /**
   * 「+既存から選択」モーダルの OK: チェックの差分(追加/登録解除)をまとめて
   * machines/<machine>.json へ適用する。handleMachineDeviceUpdate と同じ理由でモーダル確認なし・
   * resolveProjectName 直接呼びとする。
   */
  handleMachineDevicesSync(message: MachineDevicesSyncMessage): void {
    const sendResult = (ok: boolean, added: number, removed: number, error: string | null) => {
      this.deps.post({ type: "machineDevicesSyncResult", ok, added, removed, error });
    };

    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(false, 0, 0, "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。");
      return;
    }

    const machinePath = path.join(this.machinesDir(resolution.project), `${message.machine}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(machinePath, "utf8"));
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」の読み込みに失敗しました: ${String(error)}`,
      );
      sendResult(false, 0, 0, `マシンプロファイル「${message.machine}」を読み込めませんでした。`);
      return;
    }

    const result = syncDevicesInMachineProfile(parsed, message.add, message.remove);
    if (!result.ok) {
      sendResult(false, 0, 0, result.error);
      return;
    }

    try {
      fs.writeFileSync(machinePath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」へのデバイス同期の書き込みに失敗しました: ${String(error)}`,
      );
      sendResult(false, 0, 0, `マシンプロファイル「${message.machine}」への書き込みに失敗しました。`);
      return;
    }

    this.deps.outputChannel.appendLine(
      `[ftester] マシンプロファイル「${message.machine}」に追加${result.added.length}台・登録解除${result.removed}台を適用しました` +
        `(追加: ${result.added.length > 0 ? result.added.join("、") : "なし"}、` +
        `登録解除: ${message.remove.length > 0 ? message.remove.join("、") : "なし"})。`,
    );
    sendResult(true, result.added.length, result.removed, null);
    // FileSystemWatcher 経由でも呼ばれるが、反映を待たせないようここでも明示的に呼ぶ
    // (handleMachineDeviceRemove と同じ理由)。
    this.postMachineProfileInfo();
  }

  // ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム(runProfileLoad/runProfileSave) ----
  // クライアント検証済みでも updateRunProfileInObject 側の防御的検証(defaultTimeout の型)に
  // 引っかかりうるため、結果は machineDeviceUpdate と同じくモーダル確認なしに即座に返す。

  /**
   * ロード要求への応答。対象プロジェクトが解決できない/読み込み失敗/JSON解析失敗/非オブジェクトの
   * いずれも ok:false + fields:null で返す(フォーム側はこれを「表示できない」として扱う)。
   */
  handleRunProfileLoad(profile: string): void {
    const sendResult = (ok: boolean, error: string | null, fields: RunProfileFormFields | null) => {
      this.deps.post({ type: "runProfileData", profile, ok, error, fields });
    };

    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(
        false,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        null,
      );
      return;
    }

    const runPath = path.join(this.runsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(runPath, "utf8"));
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `実行プロファイル「${profile}」を読み込めませんでした。`, null);
      return;
    }

    const fields = parseRunProfileForForm(parsed);
    if (!fields) {
      sendResult(false, `実行プロファイル「${profile}」の形式が不正です。`, null);
      return;
    }
    sendResult(true, null, fields);
  }

  /**
   * 「確定」への応答。書き込み成功後、handleRunProfileLoad を呼び直して最新の fields を再送する
   * (保存直後にフォームを最新化するため)。
   */
  handleRunProfileSave(message: RunProfileSaveMessage): void {
    const { profile, fields } = message;
    const sendResult = (ok: boolean, error: string | null) => {
      this.deps.post({ type: "runProfileSaveResult", profile, ok, error });
    };

    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(false, "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。");
      return;
    }

    const runPath = path.join(this.runsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(runPath, "utf8"));
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `実行プロファイル「${profile}」を読み込めませんでした。`);
      return;
    }

    const result = updateRunProfileInObject(parsed, fields);
    if (!result.ok) {
      sendResult(false, result.error);
      return;
    }

    try {
      fs.writeFileSync(runPath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」の書き込みに失敗しました: ${String(error)}`);
      sendResult(false, `実行プロファイル「${profile}」への書き込みに失敗しました。`);
      return;
    }

    this.deps.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」を更新しました。`);
    sendResult(true, null);
    this.handleRunProfileLoad(profile);
  }

  // ---- プロファイルタブ中段: アプリプロファイルの設定フォーム(appProfileLoad/appProfileSave) ----
  // handleRunProfileLoad/handleRunProfileSave と同じ形(全フィールド省略可のため ok:false は
  // 実質発生しない想定)。

  /** ロード要求への応答(handleRunProfileLoad と同じ契約: ok:false + fields:null で失敗を返す)。 */
  handleAppProfileLoad(profile: string): void {
    const sendResult = (ok: boolean, error: string | null, fields: AppProfileFormFields | null) => {
      this.deps.post({ type: "appProfileData", profile, ok, error, fields });
    };

    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(
        false,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        null,
      );
      return;
    }

    const appPath = path.join(this.appsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(appPath, "utf8"));
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `アプリプロファイル「${profile}」を読み込めませんでした。`, null);
      return;
    }

    const fields = parseAppProfileForForm(parsed);
    if (!fields) {
      sendResult(false, `アプリプロファイル「${profile}」の形式が不正です。`, null);
      return;
    }
    sendResult(true, null, fields);
  }

  /** 「確定」への応答(handleRunProfileSave と同じく handleAppProfileLoad 再呼び出しでフォームを最新化)。 */
  handleAppProfileSave(message: AppProfileSaveMessage): void {
    const { profile, fields } = message;
    const sendResult = (ok: boolean, error: string | null) => {
      this.deps.post({ type: "appProfileSaveResult", profile, ok, error });
    };

    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(false, "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。");
      return;
    }

    const appPath = path.join(this.appsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(appPath, "utf8"));
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `アプリプロファイル「${profile}」を読み込めませんでした。`);
      return;
    }

    const result = updateAppProfileInObject(parsed, fields);
    if (!result.ok) {
      sendResult(false, result.error);
      return;
    }

    try {
      fs.writeFileSync(appPath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」の書き込みに失敗しました: ${String(error)}`);
      sendResult(false, `アプリプロファイル「${profile}」への書き込みに失敗しました。`);
      return;
    }

    this.deps.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」を更新しました。`);
    sendResult(true, null);
    this.handleAppProfileLoad(profile);
  }
}
