// monitorRecordingsController.ts
// デバイスモニターパネル「録画」タブ: セッション一覧(recordingsStore.ts)の供給と、選択セッションの
// 再生データ(動画 webview URI + エラー一覧のオフセット。recordingsModel.ts)の組み立てを行う。
// 動画ファイルの webview URI 変換は MonitorPanelDeps.videoWebviewUri 経由(他サブコントローラを
// 直接参照しない方針。monitorPanel.ts 冒頭参照)。

import * as path from "node:path";
import {
  buildRecordingErrorEntries,
  buildRecordingTree,
  firstRecordingEntryByScenario,
  groupTreeByClass,
  extractScenarioFailureSource,
  extractScenarioTreeSource,
  type RecordingScenarioVideo,
} from "./recordingsModel";
import { listRecordingSessions, loadRecordingSessionDetail } from "./recordingsStore";
import type { MonitorPanelDeps } from "./monitorPanel";

export class MonitorRecordingsController {
  constructor(private readonly deps: MonitorPanelDeps) {}

  async refreshSessions(): Promise<void> {
    const sessions = await listRecordingSessions(this.deps.workspaceRoot);
    this.deps.post({ type: "recordingsSessions", sessions });
  }

  async openSession(project: string, runID: string): Promise<void> {
    const detail = await loadRecordingSessionDetail(this.deps.workspaceRoot, project, runID);
    if (!detail) {
      this.deps.post({
        type: "recordingsSession",
        ok: false,
        project,
        runID,
        error: "recordings not found",
        videos: null,
        errors: null,
        tree: null,
      });
      return;
    }
    // scenarioID ごとに最初にマッチしたエントリの動画だけ webview URI 化する(revive 再実行での
    // 重複 scenarioID は recordingsModel.ts 側と同じ「最初の1件」規約)。
    const videos: RecordingScenarioVideo[] = [];
    for (const [scenarioID, entry] of firstRecordingEntryByScenario(detail.index.recordings)) {
      const videoUri = this.deps.videoWebviewUri(path.join(detail.runDir, entry.file));
      if (videoUri) {
        videos.push({ scenarioID, videoUri });
      }
    }
    const failureSources = detail.scenarios
      .map(extractScenarioFailureSource)
      .filter((s): s is NonNullable<typeof s> => s !== null);
    const errors = buildRecordingErrorEntries(failureSources, detail.index.recordings);
    const treeSources = detail.scenarios
      .map(extractScenarioTreeSource)
      .filter((s): s is NonNullable<typeof s> => s !== null);
    const tree = groupTreeByClass(buildRecordingTree(treeSources, detail.index.recordings));
    this.deps.post({ type: "recordingsSession", ok: true, project, runID, error: null, videos, errors, tree });
  }
}
