// monitorRecordingsController.ts
// デバイスモニターパネル「録画」タブ: セッション一覧(recordingsStore.ts)の供給と、選択セッションの
// 再生データ(動画 webview URI + エラー一覧のオフセット。recordingsModel.ts)の組み立てを行う。
// 動画ファイルの webview URI 変換は MonitorPanelDeps.videoWebviewUri 経由(他サブコントローラを
// 直接参照しない方針。monitorPanel.ts 冒頭参照)。

import * as fs from "node:fs/promises";
import * as path from "node:path";
import { listProjectCandidates, resolveProjectName } from "./config";
import { t } from "./i18n";
import {
  buildRecordingErrorEntries,
  buildRecordingTree,
  buildScenarioDevices,
  firstRecordingEntryByScenario,
  groupTreeByClass,
  extractScenarioFailureSource,
  extractScenarioTreeSource,
  type RecordingErrorEntry,
  type RecordingScenarioDevice,
  type RecordingScenarioVideo,
  type RecordingTreeScenario,
} from "./recordingsModel";
import {
  listRecordingSessions,
  loadRecordingSessionDetail,
  loadRunMeta,
  type RecordingSessionSummary,
  resolveSessionRunIDs,
} from "./recordingsStore";
import type { MonitorPanelDeps } from "./monitorPanel";
import { selectWorkspaceProject } from "./projectSelection";
import type { MonitorToWebviewMessage } from "./monitorWebviewMessages";
import {
  buildResultsExportModel,
  extractResultsExportScenarioSource,
  type ResultsExportRunMeta,
  type ResultsExportScenarioSource,
} from "./resultsExportModel";
import { buildResultsExportWorkbook } from "./resultsExportWorkbook";

type RecordingsSessionMessage = Extract<MonitorToWebviewMessage, { type: "recordingsSession" }>;

/** 「(すべて)」選択の保存先(monitorPanel.ts が workspaceState "monitor.recordingsAllProjects" で渡す)。 */
export interface RecordingsAllProjectsStore {
  get(): boolean;
  set(value: boolean): void;
}

/** 前回読み込んだ一覧の保存先(monitorPanel.ts が workspaceState "monitor.recordingsSessionsCache" で渡す)。
 *  鍵はプロジェクト名、「(すべて)」は ALL_PROJECTS_CACHE_KEY。 */
export interface RecordingsSessionsCache {
  get(key: string): readonly RecordingSessionSummary[] | undefined;
  set(key: string, sessions: readonly RecordingSessionSummary[]): void;
}

/** プロジェクト名(TestProjects/ のディレクトリ名)と衝突しない鍵。 */
export const ALL_PROJECTS_CACHE_KEY = "\u0000all";

function memoryCache(): RecordingsSessionsCache {
  const entries = new Map<string, readonly RecordingSessionSummary[]>();
  return { get: (key) => entries.get(key), set: (key, sessions) => void entries.set(key, sessions) };
}

export class MonitorRecordingsController {
  /** refreshSessions の世代。追い越された読み込みの結果は送らない(新しい選択の一覧を古い結果で上書きしない)。 */
  private refreshGeneration = 0;

  constructor(
    private readonly deps: MonitorPanelDeps,
    private readonly allProjects: RecordingsAllProjectsStore = { get: () => false, set: () => {} },
    private readonly sessionsCache: RecordingsSessionsCache = memoryCache(),
  ) {}

  /** 一覧は選択中のプロジェクト(fleetest.project の解決結果)だけ。未解決なら空で、選択から復帰させる。
   *  「(すべて)」選択中は全プロジェクト横断。
   *  **前回の結果があれば先に refreshing:true で送り、読み込み後に差し替える** —— 列挙は run ごとの
   *  ファイル読みで、拡張ホスト起動直後は他拡張と共有の libuv スレッドプールが埋まり 30 秒かかった
   *  (単体では 0.2 秒。1 回の読みが平均 26ms 待たされ、それが run 数ぶん積み重なる)。 */
  async refreshSessions(): Promise<void> {
    const generation = ++this.refreshGeneration;
    const projects = listProjectCandidates(this.deps.workspaceRoot);
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    const current = resolution.kind === "resolved" ? resolution.project : "";
    const all = this.allProjects.get();
    const cacheKey = all ? ALL_PROJECTS_CACHE_KEY : current === "" ? null : current;
    if (cacheKey === null) {
      this.deps.post({ type: "recordingsSessions", sessions: [], projects, current, all, refreshing: false });
      return;
    }
    const cached = this.sessionsCache.get(cacheKey);
    if (cached !== undefined) {
      this.deps.post({ type: "recordingsSessions", sessions: cached, projects, current, all, refreshing: true });
    }
    const sessions = await listRecordingSessions(this.deps.workspaceRoot, all ? undefined : current);
    this.sessionsCache.set(cacheKey, sessions);
    if (generation !== this.refreshGeneration) {
      return;
    }
    this.deps.post({ type: "recordingsSessions", sessions, projects, current, all, refreshing: false });
  }

  /** 設定 fleetest.project の変更(どのタブから変えても)は「(すべて)」を解除して追従する。
   *  一覧の取り直しは呼び手(monitorPanel.ts)がパネル表示中だけ行う。 */
  onProjectSettingChanged(): void {
    this.allProjects.set(false);
  }

  /** null = 「(すべて)」。名前を選んだときは設定を書き換え、取り直しは設定変更の購読に任せる ——
   *  ただし設定が既にその値なら購読が発火しないので、ここで取り直す。 */
  async selectProject(project: string | null): Promise<void> {
    if (project === null) {
      this.allProjects.set(true);
      await this.refreshSessions();
      return;
    }
    const wasAll = this.allProjects.get();
    this.allProjects.set(false);
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind === "resolved" && resolution.project === project) {
      if (wasAll) {
        await this.refreshSessions();
      }
      return;
    }
    await selectWorkspaceProject(this.deps.workspaceRoot, this.deps.getConfig(), project);
  }

  async openSession(project: string, runID: string): Promise<void> {
    const session = await this.buildSession(project, runID);
    this.deps.post(
      session ?? {
        type: "recordingsSession",
        ok: false,
        project,
        runID,
        error: "recordings not found",
        videos: null,
        errors: null,
        tree: null,
        machine: null,
        machines: null,
        devices: null,
      },
    );
  }

  /** run 完了時の自動表示。**録画を読めたときだけ** reveal 付きで送る(録画しない run・index.json 未作成は
   *  何も送らない = 一覧ビューへ戻す ok:false も送らない)。タブを切り替えるかは webview が決める
   *  (「デバイスモニター」タブを見ているときだけ。main.js の recordingsSession)。 */
  async revealRun(project: string, runID: string): Promise<void> {
    const session = await this.buildSession(project, runID);
    if (session) {
      this.deps.post({ ...session, reveal: true });
    }
  }

  /** 「テストセッション」タブのヘッダーボタン「テスト結果をエクスポート」。開いているセッション
   *  (束ねたセッションは runGroup を共有する run 全部。buildSession と同じ解決)の
   *  scenarios/*.json を fleetest 向けレイアウトの .xlsx へ書き出す。保存先は
   *  `showSaveDialog` で利用者に確かめる(既定はセッション先頭 run の runDir 直下)。
   *  fs/vscode は deps 越し(resultsExportModel.ts/resultsExportWorkbook.ts は vscode 非依存を保つ)。 */
  async exportSession(project: string, runID: string): Promise<void> {
    try {
      const runIDs = await resolveSessionRunIDs(this.deps.workspaceRoot, project, runID);
      const pairs = await Promise.all(
        runIDs.map(async (id) => ({ runID: id, detail: await loadRecordingSessionDetail(this.deps.workspaceRoot, project, id) })),
      );
      const details = pairs.filter(
        (p): p is { runID: string; detail: NonNullable<typeof p.detail> } => p.detail !== null,
      );
      if (details.length === 0) {
        this.deps.showError(t("panels.recordings.exportNoData"));
        return;
      }
      const sources: ResultsExportScenarioSource[] = [];
      const runMetas: ResultsExportRunMeta[] = [];
      for (const { runID: rid, detail } of details) {
        const meta = await loadRunMeta(detail.runDir);
        runMetas.push({
          runID: rid,
          startedAt: meta.startedAt,
          finishedAt: meta.finishedAt,
          trigger: meta.trigger,
          issuer: meta.issuer,
          profile: meta.profile,
          machine: detail.machine,
          fmSettings: meta.fmSettings,
        });
        for (const raw of detail.scenarios) {
          const source = extractResultsExportScenarioSource(raw, meta.profile, detail.machine);
          if (source) sources.push(source);
        }
      }
      if (sources.length === 0) {
        this.deps.showError(t("panels.recordings.exportNoData"));
        return;
      }
      const model = buildResultsExportModel(project, sources, runMetas);
      const workbook = buildResultsExportWorkbook(model);

      const defaultPath = path.join(details[0]!.detail.runDir, `${project}_${runID}.xlsx`);
      const savePath = await this.deps.showSaveDialog(defaultPath, t("panels.recordings.exportFilterLabel"));
      if (savePath === undefined) {
        return; // キャンセル
      }
      await fs.writeFile(savePath, workbook.toBuffer());
      const action = await this.deps.showInfo(
        t("panels.recordings.exportSaved", { path: savePath }),
        t("panels.recordings.exportOpen"),
      );
      if (action !== undefined) {
        this.deps.openExternal(savePath);
      }
    } catch (e) {
      this.deps.showError(t("panels.recordings.exportError", { error: String(e) }));
    }
  }

  private async buildSession(project: string, runID: string): Promise<RecordingsSessionMessage | null> {
    // **束ねたセッションはディスクから引き直す**(runGroup を共有する run 全部。recordingsStore の
    // resolveSessionRunIDs)。webview が持つ一覧は古くなりうるので鍵の解決を任せない
    const runIDs = await resolveSessionRunIDs(this.deps.workspaceRoot, project, runID);
    const details = (
      await Promise.all(runIDs.map((id) => loadRecordingSessionDetail(this.deps.workspaceRoot, project, id)))
    ).filter((d): d is NonNullable<typeof d> => d !== null);
    if (details.length === 0) {
      return null;
    }
    // scenarioID ごとに最初にマッチしたエントリの動画だけ webview URI 化する(revive 再実行での
    // 重複 scenarioID は recordingsModel.ts 側と同じ「最初の1件」規約)。**束ねたセッションでは
    // run を跨いでも同じ規約**(1シナリオは1つの機械で走るので通常は衝突しない)
    const videos: RecordingScenarioVideo[] = [];
    const seenScenarios = new Set<string>();
    const errors: RecordingErrorEntry[] = [];
    const devices: RecordingScenarioDevice[] = [];
    const treeScenarios: RecordingTreeScenario[] = [];
    const machines: string[] = [];
    let clipsAttempted: number | null = null;
    let clipsFailed: number | null = null;
    let sourcesFailed: number | null = null;
    for (const detail of details) {
      for (const [scenarioID, entry] of firstRecordingEntryByScenario(detail.index.recordings)) {
        if (seenScenarios.has(scenarioID)) {
          continue;
        }
        const videoUri = this.deps.videoWebviewUri(path.join(detail.runDir, entry.file));
        if (videoUri) {
          seenScenarios.add(scenarioID);
          videos.push({ scenarioID, videoUri });
        }
      }
      const failureSources = detail.scenarios
        .map(extractScenarioFailureSource)
        .filter((s): s is NonNullable<typeof s> => s !== null);
      errors.push(...buildRecordingErrorEntries(failureSources, detail.index.recordings));
      const treeSources = detail.scenarios
        .map(extractScenarioTreeSource)
        .filter((s): s is NonNullable<typeof s> => s !== null);
      treeScenarios.push(...buildRecordingTree(treeSources, detail.index.recordings));
      devices.push(...buildScenarioDevices(detail.index.recordings, detail.machine));
      if (detail.machine !== null && !machines.includes(detail.machine)) {
        machines.push(detail.machine);
      }
      // 切り出しの集計は index.json にしか無い(recordings が空でも run は一覧に出る契約。
      // recordingsModel.ts の RecordingIndex 参照)。再生ビューの「録画が無い理由」に使う
      if (detail.index.clipsAttempted !== undefined) {
        clipsAttempted = (clipsAttempted ?? 0) + detail.index.clipsAttempted;
      }
      if (detail.index.clipsFailed !== undefined) {
        clipsFailed = (clipsFailed ?? 0) + detail.index.clipsFailed;
      }
      if (detail.index.sourcesFailed !== undefined) {
        sourcesFailed = (sourcesFailed ?? 0) + detail.index.sourcesFailed;
      }
    }
    // エラーとツリーは機械をまたいで1つに混ぜる(壁時計順・クラス初出順。単機のときも同じ結果)
    errors.sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
    const tree = groupTreeByClass(treeScenarios);
    return {
      type: "recordingsSession",
      ok: true,
      project,
      runID,
      error: null,
      videos,
      errors,
      tree,
      machine: details[0]!.machine,
      machines,
      devices,
      clipsAttempted,
      clipsFailed,
      sourcesFailed,
    };
  }
}
