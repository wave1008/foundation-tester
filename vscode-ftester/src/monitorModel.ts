// monitorModel.ts
// モニターの純粋関数群の re-export 窓口。実体は4ファイルに分割済み(いずれも vscode に依存しない
// 純粋関数群。monitorPanel.ts と test/ の両方から同じロジックを使うための方針は従来通り):
//   - monitorDeviceModel.ts:      デバイスの型・`ftester api monitor` の NDJSON イベントの検証/整列/フィルタ
//   - monitorWebviewMessages.ts:  extension ⇔ webview の postMessage 契約(型)・検証・変換
//   - monitorDeviceLifecycle.ts:  device-up/down 等の NDJSON イベント型・デバイスライフサイクルの直列キュー
//   - monitorProfileForms.ts:     実行/アプリ/マシンプロファイルのフォーム解析・検証・デバイスカタログ
// 拡張側の import は従来通りこのファイル経由でよい(このファイル自体は re-export のみで挙動を持たない)。
// webview 側(src/webview/monitor/*.js)は CSP で import できないため、上記各ファイルのロジックを
// 個別に複製している(複製元コメントは対応する分割後ファイルを指す)。

export * from "./monitorDeviceModel";
export * from "./monitorWebviewMessages";
export * from "./monitorDeviceLifecycle";
export * from "./monitorProfileForms";
