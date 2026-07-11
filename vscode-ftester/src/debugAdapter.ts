// debugAdapter.ts
// ftester シナリオ用の Debug Adapter Protocol (DAP) 実装。
//
// "vscode" モジュールに依存しない(配線は debugConfig.ts に寄せる)。これにより
// test/dap.test.mjs は実エディタ無しでこのクラスを直接 new し handleMessage()/
// onDidSendMessage() だけでプロトコルを駆動して単体テストできる。
//
// スレッドは常に1本(THREAD_ID)。`ftester api run --debug` は --scenario を1件だけ
// 受け付ける前提に合わせている(Sources/ftester/ApiRunCommand.swift)。
//
// 制御コマンド(stdin へ書く NDJSON)と paused イベント(stdout から読む NDJSON)の
// プロトコルは Sources/FTCore/ScenarioDebug.swift のコメントに準拠する。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import * as path from "node:path";
import type { Readable, Writable } from "node:stream";
import {
  Breakpoint,
  DebugSession,
  Event,
  InitializedEvent,
  OutputEvent,
  Scope,
  Source,
  StackFrame,
  StoppedEvent,
  TerminatedEvent,
  ExitedEvent,
  Thread,
  Variable,
} from "@vscode/debugadapter";
import type { DebugProtocol } from "@vscode/debugprotocol";
import { isRunEvent, type RunStepSection } from "./model";
import { NdjsonParser } from "./ndjson";
import { createRunReducerState, reduceRunEvent, type RunReducerState } from "./runReducer";

/** このアダプタが公開する唯一のスレッド ID。 */
const THREAD_ID = 1;

/**
 * scopesRequest が返す唯一のスコープ「ステップ」の variablesReference。
 * スコープは常にこの1つだけなので、Handles を使わず固定値でよい。
 */
const STEP_SCOPE_VARIABLES_REFERENCE = 1;

/** stdin=pipe, stdout/stderr=pipe で spawn したプロセスの型。 */
type FtesterProcess = ChildProcessByStdio<Writable, Readable, Readable>;

export interface FtesterDebugSessionOptions {
  /** ftester CLI バイナリの絶対パス。 */
  binaryPath: string;
  /** spawn の cwd。リポジトリルート相対パスとの相互変換の基準にも使う。 */
  cwd: string;
  /** 診断ログの出力先(省略時は何もしない)。 */
  log?: (line: string, stream: "stdout" | "stderr") => void;
}

/** launch.json / startDebugging に渡される launch 引数。 */
export interface FtesterLaunchRequestArguments extends DebugProtocol.LaunchRequestArguments {
  project: string;
  scenario: string;
  dryRun?: boolean;
  stopOnEntry?: boolean;
  skipBuild?: boolean;
  /** FM によるロケータ自己修復(--heal)を有効にする。 */
  heal?: boolean;
  /** 実行プロファイル名。platform/port/serial との組合せ規則は startDebuggee 参照。 */
  profile?: string;
  platform?: "ios" | "android";
  port?: number;
  serial?: string;
}

/** 直前に送った制御コマンドから決まる、次の paused イベントに付ける StoppedEvent の reason。 */
type StopReason = "entry" | "step" | "breakpoint" | "pause";

interface PausedInfo {
  scenario?: string;
  index?: number;
  description?: string;
  /** リポジトリルート相対パス。 */
  file?: string;
  line?: number;
  scene?: number;
  section?: RunStepSection;
}

/** kind: "ftester.scenarioFinished" のカスタムイベント本体(runHandler.ts のデバッグプロファイルが購読する)。 */
export interface ScenarioFinishedEventBody {
  scenario?: string;
  passed?: boolean;
  reportPath?: string;
}

export class FtesterDebugSession extends DebugSession {
  private readonly binaryPath: string;
  private readonly cwd: string;
  private readonly log: (line: string, stream: "stdout" | "stderr") => void;

  private launchArgs: FtesterLaunchRequestArguments | undefined;
  private child: FtesterProcess | undefined;
  /** ブレークポイント(ファイル(リポジトリ相対) → 行番号の集合)。プロセス起動前は蓄積のみ。 */
  private readonly breakpointsByFile = new Map<string, Set<number>>();
  private lastPaused: PausedInfo | undefined;
  private nextStopReason: StopReason = "breakpoint";
  private terminatedSent = false;
  private killTimer: ReturnType<typeof setTimeout> | undefined;
  private reducerState: RunReducerState = createRunReducerState();

  constructor(options: FtesterDebugSessionOptions) {
    super();
    this.binaryPath = options.binaryPath;
    this.cwd = options.cwd;
    this.log = options.log ?? (() => undefined);
    this.setDebuggerLinesStartAt1(true);
    this.setDebuggerColumnsStartAt1(true);
  }

  // ---- DAP リクエストハンドラ ---------------------------------------------

  protected override initializeRequest(
    response: DebugProtocol.InitializeResponse,
    _args: DebugProtocol.InitializeRequestArguments,
  ): void {
    response.body = response.body ?? {};
    response.body.supportsConfigurationDoneRequest = true;
    response.body.supportsTerminateRequest = true;
    this.sendResponse(response);
    this.sendEvent(new InitializedEvent());
  }

  protected override launchRequest(
    response: DebugProtocol.LaunchResponse,
    args: FtesterLaunchRequestArguments,
  ): void {
    this.launchArgs = args;
    this.nextStopReason = args.stopOnEntry ? "entry" : "breakpoint";
    this.sendResponse(response);
  }

  protected override setBreakPointsRequest(
    response: DebugProtocol.SetBreakpointsResponse,
    args: DebugProtocol.SetBreakpointsArguments,
  ): void {
    const requested: Array<{ line: number }> =
      args.breakpoints ?? (args.lines ?? []).map((line) => ({ line }));

    const sourcePath = args.source.path;
    const relFile = sourcePath ? this.toRepoRelative(sourcePath) : undefined;
    if (relFile) {
      if (requested.length > 0) {
        this.breakpointsByFile.set(relFile, new Set(requested.map((b) => b.line)));
      } else {
        this.breakpointsByFile.delete(relFile);
      }
    }

    response.body = {
      breakpoints: requested.map((b) => {
        const source = sourcePath ? new Source(path.basename(sourcePath), sourcePath) : undefined;
        return new Breakpoint(true, b.line, undefined, source);
      }),
    };
    this.sendResponse(response);

    // プロセス起動前は蓄積のみ(--breakpoint 引数として起動時にまとめて渡す)。
    // 起動後にブレークポイントが変わった場合は、全ファイル分を集約して全置換で送る。
    if (this.child) {
      this.sendBreakpointsToChild();
    }
  }

  protected override configurationDoneRequest(
    response: DebugProtocol.ConfigurationDoneResponse,
    _args: DebugProtocol.ConfigurationDoneArguments,
  ): void {
    this.sendResponse(response);
    this.startDebuggee();
  }

  protected override continueRequest(
    response: DebugProtocol.ContinueResponse,
    _args: DebugProtocol.ContinueArguments,
  ): void {
    this.nextStopReason = "breakpoint";
    this.writeCommand({ cmd: "continue" });
    response.body = { allThreadsContinued: true };
    this.sendResponse(response);
  }

  protected override nextRequest(
    response: DebugProtocol.NextResponse,
    _args: DebugProtocol.NextArguments,
  ): void {
    this.sendStepCommand(response);
  }

  protected override stepInRequest(
    response: DebugProtocol.StepInResponse,
    _args: DebugProtocol.StepInArguments,
  ): void {
    this.sendStepCommand(response);
  }

  protected override stepOutRequest(
    response: DebugProtocol.StepOutResponse,
    _args: DebugProtocol.StepOutArguments,
  ): void {
    this.sendStepCommand(response);
  }

  protected override pauseRequest(
    response: DebugProtocol.PauseResponse,
    _args: DebugProtocol.PauseArguments,
  ): void {
    this.nextStopReason = "pause";
    this.writeCommand({ cmd: "pause" });
    this.sendResponse(response);
  }

  protected override terminateRequest(
    response: DebugProtocol.TerminateResponse,
    _args: DebugProtocol.TerminateArguments,
  ): void {
    this.sendResponse(response);
    this.stopDebuggee();
  }

  protected override disconnectRequest(
    response: DebugProtocol.DisconnectResponse,
    _args: DebugProtocol.DisconnectArguments,
  ): void {
    this.sendResponse(response);
    this.stopDebuggee();
  }

  protected override stackTraceRequest(
    response: DebugProtocol.StackTraceResponse,
    _args: DebugProtocol.StackTraceArguments,
  ): void {
    const paused = this.lastPaused;
    if (!paused || !paused.file || paused.line == null) {
      response.body = { stackFrames: [], totalFrames: 0 };
      this.sendResponse(response);
      return;
    }
    const absolutePath = this.toAbsolute(paused.file);
    const source = new Source(path.basename(absolutePath), absolutePath);
    const name = paused.description ?? paused.scenario ?? "ftester";
    const frame = new StackFrame(1, name, source, paused.line, 1);
    response.body = { stackFrames: [frame], totalFrames: 1 };
    this.sendResponse(response);
  }

  protected override scopesRequest(
    response: DebugProtocol.ScopesResponse,
    _args: DebugProtocol.ScopesArguments,
  ): void {
    // 停止中(lastPaused あり)のときだけ、スコープ「ステップ」を1つ返す。
    // 変数はステップ情報のみのフラットな一覧なので expensive: false。
    const scopes = this.lastPaused
      ? [new Scope("ステップ", STEP_SCOPE_VARIABLES_REFERENCE, false)]
      : [];
    response.body = { scopes };
    this.sendResponse(response);
  }

  protected override variablesRequest(
    response: DebugProtocol.VariablesResponse,
    args: DebugProtocol.VariablesArguments,
  ): void {
    const variables =
      args.variablesReference === STEP_SCOPE_VARIABLES_REFERENCE
        ? this.buildPausedVariables()
        : [];
    response.body = { variables };
    this.sendResponse(response);
  }

  /** lastPaused の内容を「ステップ」スコープの変数一覧に変換する。値が undefined の項目は出さない。 */
  private buildPausedVariables(): DebugProtocol.Variable[] {
    const paused = this.lastPaused;
    if (!paused) {
      return [];
    }
    const variables: DebugProtocol.Variable[] = [];
    const push = (name: string, value: unknown): void => {
      if (value === undefined) {
        return;
      }
      variables.push(new Variable(name, String(value)));
    };
    push("シナリオ", paused.scenario);
    push("ステップ番号", paused.index);
    push("コマンド", paused.description);
    push("scene", paused.scene);
    push("区分", paused.section);
    push(
      "位置",
      paused.file !== undefined && paused.line != null ? `${paused.file}:${paused.line}` : undefined,
    );
    return variables;
  }

  protected override threadsRequest(response: DebugProtocol.ThreadsResponse): void {
    response.body = { threads: [new Thread(THREAD_ID, "ftester scenario")] };
    this.sendResponse(response);
  }

  // ---- プロセス管理 ---------------------------------------------------------

  private sendStepCommand(response: DebugProtocol.Response): void {
    this.nextStopReason = "step";
    this.writeCommand({ cmd: "step" });
    this.sendResponse(response);
  }

  private allBreakpointLocations(): string[] {
    const locations: string[] = [];
    for (const [file, lines] of this.breakpointsByFile) {
      for (const line of lines) {
        locations.push(`${file}:${String(line)}`);
      }
    }
    return locations;
  }

  private sendBreakpointsToChild(): void {
    this.writeCommand({ cmd: "breakpoints", locations: this.allBreakpointLocations() });
  }

  private forwardStderrLine(line: string): void {
    this.log(line, "stderr");
    this.sendEvent(new OutputEvent(`${line}\n`, "stderr"));
  }

  private writeCommand(obj: Record<string, unknown>): void {
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null) {
      return;
    }
    try {
      child.stdin.write(`${JSON.stringify(obj)}\n`);
    } catch (error) {
      this.log(`stdin への書き込みに失敗しました: ${String(error)}`, "stderr");
    }
  }

  private startDebuggee(): void {
    const args = this.launchArgs;
    if (!args) {
      this.log("launch 引数が無いまま configurationDone を受信しました", "stderr");
      this.finishWithTerminated();
      return;
    }

    const cliArgs = ["api", "run", "--project", args.project, "--scenario", args.scenario, "--debug"];
    if (args.dryRun) {
      cliArgs.push("--dry-run");
    }
    if (args.skipBuild) {
      cliArgs.push("--skip-build");
    }
    // --heal は dry-run には付与しない(runHandler.ts の executeRun と同じ方針)。
    if (args.heal && !args.dryRun) {
      cliArgs.push("--heal");
    }
    if (args.stopOnEntry) {
      cliArgs.push("--pause-on-start");
    }
    for (const location of this.allBreakpointLocations()) {
      cliArgs.push("--breakpoint", location);
    }
    // --profile と --platform/--port/--serial は ftester api run 側で同時指定不可なので、
    // profile が非空のときはそちらだけを渡す(runHandler.ts の executeDebugRun と同じ方針)。
    if (args.profile && args.profile.trim().length > 0) {
      cliArgs.push("--profile", args.profile.trim());
    } else {
      if (args.platform) {
        cliArgs.push("--platform", args.platform);
      }
      if (args.port) {
        cliArgs.push("--port", String(args.port));
      }
      if (args.serial && args.serial.trim().length > 0) {
        cliArgs.push("--serial", args.serial);
      }
    }

    let child: FtesterProcess;
    try {
      child = spawn(this.binaryPath, cliArgs, {
        cwd: this.cwd,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.forwardStderrLine(`ftester CLI の起動に失敗しました: ${String(error)}`);
      this.finishWithTerminated();
      return;
    }
    this.child = child;
    // プロセス終了直後の writeCommand() で EPIPE が非同期 'error' として発火し、リスナーが
    // 無いと Node プロセスごと落ちる。ScenarioRunControl.send() と同じ理由で無視してよい。
    child.stdin.on("error", () => undefined);

    const stdoutParser = new NdjsonParser(
      (value) => this.handleNdjsonValue(value),
      (line) => this.log(line, "stdout"),
    );
    child.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));

    // stderr は JSON になることはまず無いが、NdjsonParser を流用して行単位に切り出す
    // (UTF-8 マルチバイト文字がチャンク境界で分断されても壊れないようにするため)。
    const stderrParser = new NdjsonParser(
      (value) => this.forwardStderrLine(JSON.stringify(value)),
      (line) => this.forwardStderrLine(line),
    );
    child.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    child.on("error", (error) => {
      this.forwardStderrLine(`ftester プロセスの実行でエラーが発生しました: ${error.message}`);
      this.finishWithTerminated();
    });

    child.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.child = undefined;
      this.finishWithTerminated(exitCode ?? undefined);
    });
  }

  /** 停止コマンドを送り、2秒後もプロセスが残っていれば SIGTERM、さらに2秒後 SIGKILL する。 */
  private stopDebuggee(): void {
    if (this.killTimer) {
      clearTimeout(this.killTimer);
      this.killTimer = undefined;
    }
    const child = this.child;
    if (!child) {
      this.finishWithTerminated();
      return;
    }
    this.writeCommand({ cmd: "stop" });
    this.killTimer = setTimeout(() => {
      this.killTimer = undefined;
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGTERM");
        this.killTimer = setTimeout(() => {
          this.killTimer = undefined;
          if (child.exitCode === null && child.signalCode === null) {
            child.kill("SIGKILL");
          }
        }, 2000);
      }
    }, 2000);
  }

  private finishWithTerminated(exitCode?: number): void {
    if (this.killTimer) {
      clearTimeout(this.killTimer);
      this.killTimer = undefined;
    }
    if (this.terminatedSent) {
      return;
    }
    this.terminatedSent = true;
    this.sendEvent(new TerminatedEvent());
    this.sendEvent(new ExitedEvent(exitCode ?? 0));
  }

  // ---- NDJSON イベント処理 ---------------------------------------------------

  private handleNdjsonValue(value: unknown): void {
    // runReducer のアイコン整形をそのまま流用し、"output" アクションを OutputEvent に変換する
    // (started/passed/failed/end はこのアダプタでは使わない。scenarioFinished/paused は個別に扱う)。
    const { state, actions } = reduceRunEvent(this.reducerState, value, Date.now());
    this.reducerState = state;
    for (const action of actions) {
      if (action.type === "output") {
        this.sendEvent(new OutputEvent(`${action.text}\n`, "stdout"));
      }
    }

    if (!isRunEvent(value)) {
      return;
    }

    if (value.kind === "paused") {
      this.lastPaused = {
        scenario: value.scenario,
        index: value.index,
        description: value.description,
        file: value.file,
        line: value.line,
        scene: value.scene,
        section: value.section,
      };
      this.sendEvent(new StoppedEvent(this.nextStopReason, THREAD_ID));
      return;
    }

    if (value.kind === "scenarioFinished") {
      const body: ScenarioFinishedEventBody = {
        scenario: value.scenario,
        passed: value.passed,
        reportPath: value.reportPath,
      };
      this.sendEvent(new Event("ftester.scenarioFinished", body));
    }
  }

  // ---- パス変換 ---------------------------------------------------------------

  /** 絶対パス → リポジトリルート相対パス(スラッシュ区切りに正規化)。 */
  private toRepoRelative(absolutePath: string): string {
    const rel = path.relative(this.cwd, absolutePath);
    return rel.split(path.sep).join("/");
  }

  /** リポジトリルート相対パス(既に絶対ならそのまま) → 絶対パス。 */
  private toAbsolute(relativeOrAbsolute: string): string {
    return path.isAbsolute(relativeOrAbsolute)
      ? relativeOrAbsolute
      : path.join(this.cwd, relativeOrAbsolute);
  }
}
