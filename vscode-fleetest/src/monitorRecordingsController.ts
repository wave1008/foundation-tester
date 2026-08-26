// monitorRecordingsController.ts
// デバイスモニターパネル「録画」タブ: セッション一覧(recordingsStore.ts)の供給と、選択セッションの
// 再生データ(動画 webview URI + エラー一覧のオフセット。recordingsModel.ts)の組み立てを行う。
// 動画ファイルの webview URI 変換は MonitorPanelDeps.videoWebviewUri 経由(他サブコントローラを
// 直接参照しない方針。monitorPanel.ts 冒頭参照)。

import * as path from "node:path";
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
import { listRecordingSessions, loadRecordingSessionDetail, resolveSessionRunIDs } from "./recordingsStore";
import type { MonitorPanelDeps } from "./monitorPanel";

export class MonitorRecordingsController {
  constructor(private readonly deps: MonitorPanelDeps) {}

  async refreshSessions(): Promise<void> {
    const sessions = await listRecordingSessions(this.deps.workspaceRoot);
    this.deps.post({ type: "recordingsSessions", sessions });
  }

  async openSession(project: string, runID: string): Promise<void> {
    // **束ねたセッションはディスクから引き直す**(runGroup を共有する run 全部。recordingsStore の
    // resolveSessionRunIDs)。webview が持つ一覧は古くなりうるので鍵の解決を任せない
    const runIDs = await resolveSessionRunIDs(this.deps.workspaceRoot, project, runID);
    const details = (
      await Promise.all(runIDs.map((id) => loadRecordingSessionDetail(this.deps.workspaceRoot, project, id)))
    ).filter((d): d is NonNullable<typeof d> => d !== null);
    if (details.length === 0) {
      this.deps.post({
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
      });
      return;
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
    let encoderFallback = false;
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
      encoderFallback = encoderFallback || (detail.index.encoderFallback ?? false);
    }
    // エラーとツリーは機械をまたいで1つに混ぜる(壁時計順・クラス初出順。単機のときは従来と同じ)
    errors.sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
    const tree = groupTreeByClass(treeScenarios);
    this.deps.post({
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
      encoderFallback,
    });
  }
}
