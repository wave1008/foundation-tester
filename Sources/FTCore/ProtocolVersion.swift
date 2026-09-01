// fleetest CLI ↔ VSCode 拡張の機械可読プロトコル(fleetest api ... の JSON/NDJSON)の版。
// この契約(api の JSON 形・NDJSON イベント形)を後方非互換に変える時だけ +1 する。
// ミラー: vscode-fleetest/src/protocolVersion.ts の FLEETEST_PROTOCOL_VERSION と必ず一致させること
// (vscode-fleetest/test/protocolVersion.test.mjs が不一致を検出する)。
public let fleetestProtocolVersion = 10
