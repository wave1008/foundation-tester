// バッチD 辞書。namespace: live.
// 対象ソース: monitorLiveController.ts, liveModel.ts, livePanel.ts, deviceStream.ts
// キーは "live." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const liveStrings = {
  // ---- monitorLiveController.ts: serve 常駐プロセス・デバイス起動・エラー文言 ----
  "live.serveUnavailableMessage": {
    ja: "ライブ操作の常駐プロセスが起動していません。デバイスを選び直してください。",
    en: "The Live Control resident process is not running. Please reselect the device.",
  },
  "live.serveTimeoutMessage": {
    ja: "ライブ操作の応答がタイムアウトしました(常駐プロセスが応答していません)。",
    en: "The Live Control response timed out (the resident process is not responding).",
  },
  "live.serveClosedMessage": {
    ja: "ライブ操作の常駐プロセスが終了しました。",
    en: "The Live Control resident process has exited.",
  },
  "live.projectUnresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the ftester.project setting.",
  },
  "live.projectUnresolvedShort": {
    ja: "対象のテストプロジェクトを解決できませんでした。",
    en: "Could not resolve the target test project.",
  },
  "live.deviceListFailedDetail": {
    ja: "デバイス一覧の取得に失敗しました。マシンプロファイルの設定を確認してください({detail})",
    en: "Failed to fetch the device list. Check the machine profile configuration ({detail})",
  },
  "live.deviceListFailedError": {
    ja: "デバイス一覧の取得に失敗しました: {error}",
    en: "Failed to fetch the device list: {error}",
  },
  "live.deviceBooting": {
    ja: "デバイス「{name}」を起動しています…(初回は数十秒かかることがあります)",
    en: 'Starting device "{name}"… (the first boot can take tens of seconds)',
  },
  "live.deviceBootFailed": {
    ja: "デバイス「{name}」の起動に失敗しました。",
    en: 'Failed to start device "{name}".',
  },
  "live.deviceBootFailedError": {
    ja: "デバイス「{name}」の起動に失敗しました: {error}",
    en: 'Failed to start device "{name}": {error}',
  },
  "live.serveSpawnFailed": {
    ja: "[live serve] プロセスの起動に失敗しました: {error}",
    en: "[live serve] Failed to start process: {error}",
  },
  "live.serveProcessError": {
    ja: "[live serve] プロセスでエラーが発生しました: {error}",
    en: "[live serve] Process error: {error}",
  },
  "live.serveGiveUpEarlyExit": {
    ja: "[live serve] 起動直後の異常終了が続いたため自動再起動を停止しました。デバイスを選び直すか、パネルを開き直すと再試行します。",
    en: "[live serve] Stopped automatic restart after repeated early exits. Reselect the device or reopen the panel to retry.",
  },
  "live.serveGiveUpTimeout": {
    ja: "[live serve] 応答タイムアウトによる再起動が連続したため自動再起動を停止しました。デバイスを選び直すか、パネルを開き直してください。",
    en: "[live serve] Stopped automatic restart after repeated response-timeout restarts. Reselect the device or reopen the panel.",
  },
  "live.serveTimeoutRestart": {
    ja: "[live serve] 応答が{seconds}秒返らないため常駐プロセスを再起動します。",
    en: "[live serve] No response for {seconds}s. Restarting the resident process.",
  },
  "live.serveUnknownLine": {
    ja: "[live serve] 未知の形式の行を無視しました: {value}",
    en: "[live serve] Ignored a line in unknown format: {value}",
  },
  "live.serveNoPendingRequest": {
    ja: "[live serve] 対応するリクエストが無いイベントを受信しました({kind})",
    en: "[live serve] Received an event with no matching pending request ({kind})",
  },
  "live.serveMismatchedEvent": {
    ja: "[live serve] 対応しないイベントを受信しました(期待: {expected}、実際: {actual})",
    en: "[live serve] Received a mismatched event (expected: {expected}, actual: {actual})",
  },
  "live.internalErrorSnapshotMissing": {
    ja: "内部エラー: snapshot が届きませんでした。",
    en: "Internal error: snapshot was not received.",
  },
  "live.internalErrorFrameMissing": {
    ja: "内部エラー: frame が届きませんでした。",
    en: "Internal error: frame was not received.",
  },
  "live.noDeviceSelected": {
    ja: "デバイスが選択されていません。",
    en: "No device is selected.",
  },
  "live.snapshotFailed": {
    ja: "snapshot の実行に失敗しました: {error}",
    en: "Failed to run snapshot: {error}",
  },
  "live.streamGiveUpSwitchPolling": {
    ja: "[live-stream] {message} ポーリングに切り替えます。",
    en: "[live-stream] {message} Switching to polling.",
  },
  "live.actionFailed": {
    ja: "操作の実行に失敗しました: {error}",
    en: "Failed to run the action: {error}",
  },
  "live.appProfileUnresolved": {
    ja: "アプリプロファイルを解決できません",
    en: "Could not resolve the app profile",
  },
  "live.recordStarting": {
    ja: "レコーディングを開始しています…",
    en: "Starting recording…",
  },
  "live.recordNoSteps": {
    ja: "操作が記録されていません",
    en: "No actions were recorded",
  },
  "live.tempFileWriteFailed": {
    ja: "一時ファイルの書き込みに失敗しました: {error}",
    en: "Failed to write the temporary file: {error}",
  },
  "live.generatingCode": {
    ja: "テストコードを生成中…",
    en: "Generating test code…",
  },
  "live.codeGenFailed": {
    ja: "テストコードの生成に失敗しました。",
    en: "Failed to generate test code.",
  },
  "live.refreshFirst": {
    ja: "先に「更新」で画面を取得してください。",
    en: 'Fetch the screen with "Refresh" first.',
  },
  "live.typeTextEmpty": {
    ja: "入力するテキストを入力してください。",
    en: "Enter the text to type.",
  },

  // ---- 「操作記録」ラベル(monitorLiveController.ts の手動操作 / liveModel.ts の
  // stepDescriptionToOperationLabel が両方使う。表示と比較を同一 t() に揃える契約) ----
  "live.opLabel.tap": { ja: "タップ: {target}", en: "Tap: {target}" },
  "live.opLabel.tapPlain": { ja: "タップ", en: "Tap" },
  "live.opLabel.press": { ja: "ロングプレス: {target}", en: "Long press: {target}" },
  "live.opLabel.type": { ja: "入力: {text}", en: "Input: {text}" },
  "live.opLabel.scrollTo": { ja: "スクロール: {target}", en: "Scroll: {target}" },
  "live.opLabel.swipe": { ja: "スワイプ: {direction}", en: "Swipe: {direction}" },
  "live.opLabel.home": { ja: "ホーム", en: "Home" },
  "live.opLabel.appSwitcher": { ja: "タスク切替", en: "App Switcher" },
  "live.opLabel.launch": { ja: "起動: {bundle}", en: "Launch: {bundle}" },
  "live.opLabel.terminate": { ja: "終了", en: "Terminate" },
  "live.opLabel.wait": { ja: "待機: {seconds}秒", en: "Wait: {seconds}s" },
  "live.direction.up": { ja: "上", en: "Up" },
  "live.direction.down": { ja: "下", en: "Down" },
  "live.direction.left": { ja: "左", en: "Left" },
  "live.direction.right": { ja: "右", en: "Right" },

  // ---- liveModel.ts: フォールバックデバイス・要素一覧表示 ----
  "live.fallbackDeviceName": {
    ja: "設定のデバイス",
    en: "Configured device",
  },
  "live.fallbackDeviceDetail": {
    ja: "ftester.platform/port/serial 設定から作成",
    en: "Created from ftester.platform/port/serial settings",
  },
  "live.elementLine.label": {
    ja: "「{label}」",
    en: '"{label}"',
  },

  // ---- livePanel.ts ----
  "live.panel.streamStallRestart": {
    ja: "[live-stream] キーフレーム未受信のままのためヘルパーを再起動します。",
    en: "[live-stream] No keyframe received. Restarting helper.",
  },
  "live.panel.codecFallback": {
    ja: "[live-stream] WebCodecs 未対応/デコード失敗のため mjpeg へフォールバックします。",
    en: "[live-stream] WebCodecs unsupported or decode failed. Falling back to mjpeg.",
  },
  "live.panel.statusBarLabel": {
    ja: "$(device-mobile) ライブ操作",
    en: "$(device-mobile) Live Control",
  },
  "live.panel.statusBarTooltip": {
    ja: "ftester: ライブ操作を表示",
    en: "ftester: Show Live Control",
  },

  // ---- deviceStream.ts: helper プロセス管理ログ(helper 自身の stdout/stderr 内容ではなく、
  // このモジュール自身が生成する診断メッセージのみ。契約はファイル冒頭コメント参照) ----
  "live.stream.spawnFailed": {
    ja: "起動に失敗しました: {error}",
    en: "Failed to start: {error}",
  },
  "live.stream.processError": {
    ja: "[{prefix}] プロセスエラー: {error}",
    en: "[{prefix}] Process error: {error}",
  },
  "live.stream.unknownKind": {
    ja: "[{prefix}] 未知の KIND({kind})を受信しました(プロトコル不整合)。helper を再起動します。",
    en: "[{prefix}] Received unknown KIND ({kind}) (protocol mismatch). Restarting helper.",
  },
  "live.stream.gaveUp": {
    ja: "[{prefix}] 起動直後の異常終了が続いたため画面ストリーミングを停止します({reason})。",
    en: "[{prefix}] Stopping screen streaming after repeated early exits ({reason}).",
  },
  "live.stream.failureMessage": {
    ja: "画面ストリーミングを継続できませんでした({reason})。",
    en: "Could not continue screen streaming ({reason}).",
  },
  "live.stream.restarting": {
    ja: "[{prefix}] 予期しない終了({reason})。{delay}ms 後に再起動します。",
    en: "[{prefix}] Unexpected exit ({reason}). Restarting in {delay}ms.",
  },
  "live.stream.wedgeRestart": {
    ja: "[{prefix}] {seconds}秒フレームが届かないため helper を再起動します。",
    en: "[{prefix}] No frame received for {seconds}s. Restarting helper.",
  },
} satisfies MessageDict;
