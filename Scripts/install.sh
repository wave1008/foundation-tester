#!/usr/bin/env bash
# foundation-tester インストーラ。/ftester-setup スキルの「機械作業」だけを1コマンドに固めたもの。
#
#   bash Scripts/install.sh --work-dir <受け手ディレクトリ> --name <ProjectName> [--app <bundleID>]
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
#     | bash -s -- --name <ProjectName>          # clone から丸ごと(TOOL_ROOT は隣に作られる)
#
# やること: clone(既存クローンは git pull --ff-only で更新)/ swift build /
#           ftester init(または project create)/ .gitignore 整備 / VSCode 拡張 / .mcp.json /
#           検証ゲート。**冪等**(済んだ手順は skip)。
#           --machine と --app-name があればプロファイル作成(profile setup --auto-device)も。
# やらないこと: appPath や bundle ID の探索
#           (値は引数で受けるだけ。スキルの「探索禁止」原則と対)。
#
# 契約: 各手順は .claude/skills/ftester-setup/SKILL.md のステップ番号と 1:1。失敗時は
#       「→ SKILL.md ステップ N」を出すので、エージェントはそこだけ手作業で直して再実行する
#       (この対応表を崩すときは SKILL.md 側も一緒に直す)。
# ログ: 全出力を <WORK_DIR>/.ftester/install-<日時>.log にも落とす(実行ごとに別ファイル)。
# 終了コード: 0=完了 / 1=必須ステップの失敗 / 2=任意ステップのみ失敗(CLI は使える)
set -euo pipefail

# FTESTER_REPO_URL はフォーク・ローカル検証用の差し替え口(既定は本家)
REPO_URL="${FTESTER_REPO_URL:-https://github.com/wave1008/foundation-tester.git}"
WORK_DIR="$PWD"
TOOL_ROOT_ARG=""
PROJECT_NAME=""
APP_ID=""
APP_NAME=""
MACHINE=""
PLATFORM="both"
DO_EXTENSION=1
DO_PROJECT=1
DO_MCP=1
DO_DOCTOR=1
DO_NEXT_STEPS=1
ALLOW_CLONE=1
ALLOW_PULL=1

usage() {
  cat <<'EOF'
使い方: install.sh [オプション]

  --work-dir <dir>   Projects/ を置く受け手ディレクトリ(既定: カレント)
  --name <name>      作成するプロジェクト名(英数字・_・-。省略時はディレクトリ名から生成)
  --app <bundleID>   対象アプリの bundle ID / パッケージ名(--app-id も可。省略可・後から差し替え可)
  --platform <p>     実行プロファイルの雛形を作る対象: ios / android / both(既定 both)
  --app-name <名>    アプリの表示名。--machine と併せて渡すとプロファイル作成まで行う
  --machine <名>     このマシンの名前(machines/<名>.json。未登録なら登録もする)
  --tool-root <dir>  foundation-tester クローンの場所(既定: <work-dir>/../foundation-tester)
  --no-clone         クローンが無くても取得しない(既存クローン必須)
  --no-pull          既存クローンを更新しない(版を固定したいとき・本体の開発中)
  --skip-extension   VSCode 拡張のインストールを行わない
  --skip-project     プロジェクト(Projects/<name>/)を作らない(MCP だけ入れるとき)
  --skip-mcp         .mcp.json の生成/マージを行わない
  --no-doctor        最後の環境レポート(ftester doctor)を省く
  --no-next-steps    「次にやること」を出さない(update.sh など呼び出し元が案内する場合)
  -h, --help         このヘルプ

やること: clone(既存なら git pull。ローカル変更は確認のうえ破棄・断れば中止)/ swift build /
         プロジェクト作成 / .gitignore 整備 / VSCode 拡張 / .mcp.json / 検証ゲート。
         **--machine と --app-name を渡すとプロファイル作成(--auto-device)まで行う**
         (冪等。済んだ手順は skip)
終了コード: 0=完了 / 2=任意ステップのみ未完(CLI と MCP は使える) / 1=必須ステップで停止
         (停止時は [fail] 行に原因と、手作業で通す手順の番号が出る)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir) WORK_DIR="${2:?--work-dir に値が必要です}"; shift 2 ;;
    --name) PROJECT_NAME="${2:?--name に値が必要です}"; shift 2 ;;
    --app|--app-id) APP_ID="${2:?--app に値が必要です}"; shift 2 ;;
    --platform) PLATFORM="${2:?--platform に値が必要です}"; shift 2 ;;
    --app-name) APP_NAME="${2:?--app-name に値が必要です}"; shift 2 ;;
    --machine) MACHINE="${2:?--machine に値が必要です}"; shift 2 ;;
    --tool-root) TOOL_ROOT_ARG="${2:?--tool-root に値が必要です}"; shift 2 ;;
    --no-clone) ALLOW_CLONE=0; shift ;;
    --no-pull) ALLOW_PULL=0; shift ;;
    --skip-extension) DO_EXTENSION=0; shift ;;
    --skip-project) DO_PROJECT=0; shift ;;
    --skip-mcp) DO_MCP=0; shift ;;
    --no-doctor) DO_DOCTOR=0; shift ;;
    --no-next-steps) DO_NEXT_STEPS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; usage >&2; exit 1 ;;
  esac
done

STEPS=()
SOFT_FAILED=0

record() { STEPS+=("$1|$2|$3"); }

print_summary() {
  echo ""
  echo "──────── インストール結果 ────────"
  local entry name status detail icon
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r name status detail <<<"$entry"
    case "$status" in
      ok) icon="✅" ;;
      skip) icon="⏭️ " ;;
      warn) icon="⚠️ " ;;
      fail) icon="❌" ;;
      *) icon="・" ;;
    esac
    # 行頭の [status] は機械可読用(エージェントが warn/fail を拾う)。書式を変えるときは
    # SKILL.md の「インストーラの読み方」も直す
    echo "${icon} [${status}] ${name}: ${detail}"
  done
}

die() {
  record "$1" fail "$2"
  print_summary
  echo ""
  echo "❌ 中断しました。→ .claude/skills/ftester-setup/SKILL.md ステップ $3 を手作業で通してから、"
  echo "   同じ引数で install.sh を再実行してください(済んだ手順は skip されます)。" >&2
  [ -n "${LOG_FILE:-}" ] && echo "   ログ: $LOG_FILE"
  exit 1
}

soft_fail() {
  record "$1" warn "$2 → SKILL.md ステップ $3"
  SOFT_FAILED=1
}

abspath() { (cd "$1" 2>/dev/null && pwd); }

# ---- 0. 前提(SKILL ステップ0) -------------------------------------------------
[ -d "$WORK_DIR" ] || die "前提" "--work-dir が存在しません: $WORK_DIR" 0
WORK_DIR="$(abspath "$WORK_DIR")"

# ここから先の出力をすべてログにも落とす(失敗の報告に丸ごと添付できるようにする)。
# 実行のたびに別ファイル(前回の記録を上書きしない)。人への質問は /dev/tty へ直接書くので
# tee の影響を受けない。ログを作れない場合でもインストールは続行する
LOG_FILE=""
if mkdir -p "$WORK_DIR/.ftester" 2>/dev/null; then
  LOG_FILE="$WORK_DIR/.ftester/install-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "==> ログ: $LOG_FILE"
fi

[ "$(uname -s)" = "Darwin" ] || die "前提" "macOS 専用です(iOS シミュレータが要る)" 0
command -v git >/dev/null 2>&1 || die "前提" "git が見つかりません" 0
command -v swift >/dev/null 2>&1 || die "前提" "swift が見つかりません(Xcode を導入してください)" 0

if ! xcodebuild -version >/dev/null 2>&1; then
  # 原因の切り分け(license 未同意 / xcode-select が CommandLineTools / Xcode 未導入)は
  # preflight.sh に一本化してある。ここでは同じ判定を二重に持たない
  die "前提" "xcodebuild が使えません。原因と対処は Scripts/preflight.sh が切り分けます(license 未同意・xcode-select が CommandLineTools を指す・Xcode 未導入。いずれも sudo が要るので人間が実行)" 0
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  die "前提" "Xcode の初回セットアップが未了です(xcodebuild -runFirstLaunch を実行してください)" 0
fi
xcode_version="$(xcodebuild -version 2>/dev/null)"
# `xcodebuild -version | head -1` はダメ(pipefail 下で SIGPIPE を失敗と誤判定する。preflight.sh の
# first_line のコメント参照)。パラメータ展開で1行目を取る
record "前提" ok "macOS $(sw_vers -productVersion) / ${xcode_version%%$'\n'*}"

# ---- 0.5 TOOL_ROOT(SKILL ステップ0.5) ----------------------------------------
# クローン内から実行されたならそれが TOOL_ROOT(curl | bash では $0 が読めないので clone へ倒す)
SELF_ROOT=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
  if [ -n "$candidate" ] && [ -f "$candidate/Package.swift" ] && [ -d "$candidate/Sources/FTScenarioRunner" ]; then
    SELF_ROOT="$candidate"
  fi
fi

if [ -n "$TOOL_ROOT_ARG" ]; then
  TOOL_ROOT_RAW="$TOOL_ROOT_ARG"
elif [ -n "$SELF_ROOT" ]; then
  TOOL_ROOT_RAW="$SELF_ROOT"
else
  TOOL_ROOT_RAW="$WORK_DIR/../foundation-tester"
fi

if [ -d "$TOOL_ROOT_RAW/.git" ] || [ -f "$TOOL_ROOT_RAW/Package.swift" ]; then
  TOOL_ROOT="$(abspath "$TOOL_ROOT_RAW")" || die "clone" "TOOL_ROOT を解決できません: $TOOL_ROOT_RAW" 0.5
  # 既存クローンは更新してから使う(古いまま build して「入れ直したのに直らない」を防ぐ)。
  # マージコミットを勝手に作らないため ff-only。版固定(detached)は意図的とみなして触らない。
  # ローカル変更は**人に確認してから**破棄する(黙って捨てない)
  if [ "$ALLOW_PULL" = "0" ]; then
    record "clone" skip "既存クローンをそのまま使用(--no-pull): $TOOL_ROOT"
  elif [ ! -d "$TOOL_ROOT/.git" ]; then
    record "clone" skip "既存ディレクトリを使用(git 管理外): $TOOL_ROOT"
  elif ! branch="$(git -C "$TOOL_ROOT" symbolic-ref --short -q HEAD)"; then
    record "clone" skip "既存クローンを使用(版固定: $(git -C "$TOOL_ROOT" describe --tags --always 2>/dev/null))"
  else
    if [ -n "$(git -C "$TOOL_ROOT" status --porcelain 2>/dev/null)" ]; then
      echo "⚠️ 既存クローンにローカル変更があります: $TOOL_ROOT"
      git -C "$TOOL_ROOT" status --short | head -20
      answer=""
      # curl | bash では stdin がスクリプト自身なので、質問と回答は端末から直接行う。
      # 制御端末が無い(エージェント・CI)と /dev/tty は存在しても open に失敗するので、
      # test -r ではなく実際に書けたかで判定する。聞けない場合は破棄せず中止する(黙って捨てない・
      # 古いクローンのまま進めない)
      if { printf "上記のローカル変更を破棄して最新へ更新しますか? [y/N]: " > /dev/tty; } 2>/dev/null; then
        read -r answer < /dev/tty 2>/dev/null || answer=""
      fi
      case "$answer" in
        [yY]*)
          # 追跡ファイルの変更だけを戻す。未追跡は消さない(clone 構成では Projects/ が
          # 未追跡のことがあり、git clean で受け手の資産を巻き込む)
          git -C "$TOOL_ROOT" reset --hard >/dev/null \
            || die "clone" "ローカル変更の破棄(git reset --hard)に失敗しました" 0.5
          echo "   → ローカル変更を破棄しました"
          ;;
        *)
          # 古いクローンのまま build すると「入れ直したのに直らない」になるため中止する
          die "clone" "ローカル変更を破棄しないため中止しました。変更を退避(git stash / commit)するか、"\
"$TOOL_ROOT で git reset --hard してから再実行してください" 0.5
          ;;
      esac
    fi
    echo "==> git pull(既存クローン $TOOL_ROOT の更新)"
    if git -C "$TOOL_ROOT" pull --ff-only; then
      record "clone" ok "既存クローンを更新: $TOOL_ROOT ($branch $(git -C "$TOOL_ROOT" rev-parse --short HEAD))"
    else
      soft_fail "clone" "git pull に失敗(既存クローンのまま続行。ネットワークか履歴の分岐を確認)" 0.5
    fi
  fi
else
  [ "$ALLOW_CLONE" = "1" ] || die "clone" "クローンがありません: $TOOL_ROOT_RAW(--no-clone 指定)" 0.5
  echo "==> clone: $REPO_URL → $TOOL_ROOT_RAW"
  git clone "$REPO_URL" "$TOOL_ROOT_RAW" || die "clone" "git clone に失敗しました" 0.5
  TOOL_ROOT="$(abspath "$TOOL_ROOT_RAW")"
  record "clone" ok "$TOOL_ROOT"
fi

[ -f "$TOOL_ROOT/Package.swift" ] && [ -d "$TOOL_ROOT/Sources/FTScenarioRunner" ] \
  || die "clone" "$TOOL_ROOT は foundation-tester のクローンではありません" 0.5

# clone 構成 = 受け手ディレクトリがクローン自身(Projects/ はクローン内に作る)
LAYOUT="external"
if [ "$WORK_DIR" = "$TOOL_ROOT" ]; then
  LAYOUT="clone"
fi
record "構成" ok "$LAYOUT(TOOL_ROOT=$TOOL_ROOT / WORK_DIR=$WORK_DIR)"

FT="$TOOL_ROOT/.build/debug/ftester"

# ---- 1. xcodegen(SKILL ステップ1) --------------------------------------------
if command -v xcodegen >/dev/null 2>&1; then
  record "xcodegen" skip "導入済み"
elif command -v brew >/dev/null 2>&1; then
  echo "==> brew install xcodegen"
  if brew install xcodegen; then
    record "xcodegen" ok "brew で導入"
  else
    die "xcodegen" "brew install xcodegen に失敗しました(iOS ブリッジ生成に必須)" 1
  fi
else
  die "xcodegen" "xcodegen も Homebrew もありません(brew install xcodegen が必要)" 1
fi

# ---- 2. ビルド(SKILL ステップ2) ----------------------------------------------
# 変数名の直後に日本語を置くときは必ず ${} で囲む(マルチバイト先頭バイトが変数名に食われる)
echo "==> swift build(${TOOL_ROOT}。初回は数分)"
( cd "$TOOL_ROOT" && swift build ) || die "ビルド" "swift build に失敗しました" 2
[ -x "$FT" ] || die "ビルド" "CLI が生成されていません: $FT" 2
# MCP サーバは .mcp.json が起動のたびにビルドし直すが、初回だけ先に通しておく(初回起動の失敗回避)
( cd "$TOOL_ROOT" && swift build --product ftester-mcp ) >/dev/null 2>&1 || true
record "ビルド" ok "$FT"

# ---- 4. プロジェクト作成(SKILL ステップ4) ------------------------------------
project_exists() {
  [ -n "$PROJECT_NAME" ] && [ -d "$WORK_DIR/Projects/$PROJECT_NAME" ]
}

# 省略可能な引数は配列で渡す(空文字列を引数として渡さないため)
APP_ARGS=()
[ -n "$APP_ID" ] && APP_ARGS=(--app "$APP_ID")
# 指示していないプラットフォームの run を作らない(machines と runs の名前不整合の温床)
PLATFORM_ARGS=(--platform "$PLATFORM")
NAME_ARGS=()
[ -n "$PROJECT_NAME" ] && NAME_ARGS=(--name "$PROJECT_NAME")

if [ "$DO_PROJECT" = "0" ]; then
  record "プロジェクト" skip "--skip-project"
elif project_exists; then
  record "プロジェクト" skip "Projects/$PROJECT_NAME は作成済み"
elif [ "$LAYOUT" = "clone" ]; then
  [ -n "$PROJECT_NAME" ] || die "プロジェクト" "clone 構成では --name が必須です" 4
  echo "==> ftester project create $PROJECT_NAME"
  ( cd "$WORK_DIR" && "$FT" project create "$PROJECT_NAME" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" \
      "${PLATFORM_ARGS[@]}" ) || die "プロジェクト" "project create に失敗しました" 4
  record "プロジェクト" ok "Projects/$PROJECT_NAME"
elif [ -f "$WORK_DIR/Package.swift" ]; then
  # ftester と無関係の既存パッケージへの導入は事故になる(init も拒否する)
  grep -q "ftester projects begin\|foundation-tester" "$WORK_DIR/Package.swift" \
    || die "プロジェクト" "$WORK_DIR/Package.swift は ftester のパッケージではありません(テスト専用の空ディレクトリで実行してください)" 0
  # 受け手パッケージは確立済み。プロジェクトだけ追加する
  [ -n "$PROJECT_NAME" ] || die "プロジェクト" "既存パッケージへの追加には --name が必要です" 4
  echo "==> ftester project create $PROJECT_NAME"
  ( cd "$WORK_DIR" && "$FT" project create "$PROJECT_NAME" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" \
      "${PLATFORM_ARGS[@]}" ) || die "プロジェクト" "project create に失敗しました" 4
  record "プロジェクト" ok "Projects/$PROJECT_NAME(既存パッケージへ追加)"
else
  # 新規の受け手パッケージ。TOOL_ROOT はローカルパス依存で引く(git 依存は手動・SKILL ステップ4参照)
  echo "==> ftester init($WORK_DIR)"
  ( cd "$WORK_DIR" && "$FT" init --ftester-path "$TOOL_ROOT" \
      "${NAME_ARGS[@]+"${NAME_ARGS[@]}"}" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" "${PLATFORM_ARGS[@]}" ) \
    || die "プロジェクト" "ftester init に失敗しました" 4
  record "プロジェクト" ok "受け手パッケージを作成${PROJECT_NAME:+(Projects/$PROJECT_NAME)}"
fi

# ---- 4 の検証ゲート: .gitignore(SKILL ステップ4) -----------------------------
# clone 構成(WORK_DIR = クローン自身)では触らない。リポジトリの .gitignore は本体が管理しており、
# ここで追記すると**クローンが dirty になり、次回の更新が pull ガードで止まる**
if [ "$LAYOUT" = "clone" ]; then
  record ".gitignore" skip "clone 構成(リポジトリ側で管理)"
elif [ -d "$WORK_DIR/.git" ]; then
  added=""
  # 対の実装: FTCore.ProjectScaffold.ensureGitignore(ftester init が使う)。片方だけ変えない
  for line in ".build/" ".ftester/" "Projects/*/reports/"; do
    if ! grep -qxF "$line" "$WORK_DIR/.gitignore" 2>/dev/null; then
      printf '%s\n' "$line" >> "$WORK_DIR/.gitignore"
      added="$added $line"
    fi
  done
  if [ -n "$added" ]; then
    record ".gitignore" ok "追記:$added"
  else
    record ".gitignore" skip "整備済み"
  fi
else
  record ".gitignore" skip "git リポジトリではない"
fi

# ---- 7. VSCode 拡張(SKILL ステップ7) -----------------------------------------
if [ "$DO_EXTENSION" = "0" ]; then
  record "拡張" skip "--skip-extension"
elif ! command -v npm >/dev/null 2>&1; then
  soft_fail "拡張" "npm がありません(Node.js を入れてから vscode-ftester で npm run install-local)" 7
else
  echo "==> VSCode 拡張のビルドとインストール"
  if ( cd "$TOOL_ROOT/vscode-ftester" && npm install && npm run install-local ); then
    record "拡張" ok "インストール済み(反映は Reload Window)"
  else
    soft_fail "拡張" "npm install / install-local が失敗(CLI と MCP は使えます)" 7
  fi
fi

# ---- 7.5 MCP サーバ登録(SKILL ステップ7.5) -----------------------------------
if [ "$DO_MCP" = "0" ]; then
  record "MCP" skip "--skip-mcp"
elif [ "$LAYOUT" = "clone" ]; then
  record "MCP" skip "clone 構成は同梱 .mcp.json が効く"
elif ! command -v python3 >/dev/null 2>&1; then
  soft_fail "MCP" "python3 が無く .mcp.json をマージできません(SKILL のテンプレートを手で書く)" 7.5
else
  MCP_JSON="$WORK_DIR/.mcp.json"
  if merge_out=$(python3 - "$MCP_JSON" "$TOOL_ROOT" <<'PY'
import json, os, sys

path, tool_root = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            print("INVALID %s" % e, end="")
            sys.exit(3)
servers = data.setdefault("mcpServers", {})
previous = servers.get("ftester", {}).get("env", {}).get("FT_TOOL_ROOT")
# cwd は受け手パッケージ(Projects/ の在り処)、FT_TOOL_ROOT はツール本体(ブリッジ資産)。
# ビルドのため TOOL_ROOT へ cd したあと exec 前に元の cwd へ戻すのが必須。
servers["ftester"] = {
    "command": "bash",
    "args": ["-lc", 'WD="$PWD"; cd "%s" && swift build --product ftester-mcp >/dev/null 2>&1 '
                    '&& cd "$WD" && exec "%s/.build/debug/ftester-mcp"' % (tool_root, tool_root)],
    "env": {"FT_TOOL_ROOT": tool_root},
}
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
if previous and previous != tool_root:
    print("REPLACED %s" % previous, end="")
else:
    print("OK", end="")
PY
  ); then
    case "$merge_out" in
      REPLACED*) record "MCP" ok ".mcp.json を更新(旧 TOOL_ROOT ${merge_out#REPLACED } を置換。旧クローンは不要なら削除)" ;;
      *) record "MCP" ok ".mcp.json に ftester を登録" ;;
    esac
  else
    soft_fail "MCP" ".mcp.json のマージに失敗($merge_out)" 7.5
  fi
fi

# ---- 5. プロファイル(SKILL ステップ5。--machine と --app-name があるときだけ) ----------
# デバイス選定は profile setup --auto-device に任せる(エージェントが simctl / emulator を
# 個別に叩くと承認回数が増える)。失敗しても導入自体は完了しているので warn 止まり
if [ "$DO_PROJECT" = "0" ]; then
  record "プロファイル" skip "--skip-project"
elif [ -z "$MACHINE" ] || [ -z "$APP_NAME" ]; then
  record "プロファイル" skip "--machine と --app-name が無いので作成しません(/ftester-profiles で作成)"
else
  echo "==> ftester profile setup(--auto-device)"
  if ( cd "$WORK_DIR" && "$FT" profile setup --platform "$PLATFORM" --auto-device \
        --machine "$MACHINE" --app-name "$APP_NAME" \
        ${PROJECT_NAME:+--project "$PROJECT_NAME"} --app-id "${APP_ID:-com.example.myapp}" ); then
    record "プロファイル" ok "machines/$MACHINE.json + apps + runs($PLATFORM)"
  else
    soft_fail "プロファイル" "profile setup に失敗(デバイスが無い等。/ftester-profiles でやり直せます)" 5
  fi
fi

# ---- 検証ゲート: ルート解決(SKILL ステップ7.5 の検証ゲート) -------------------
# ツール本体(ブリッジ資産)と受け手パッケージ(Projects/)の取り違えは ft_* を全滅させる。
# 表示された解決結果が、このインストールで意図した2ディレクトリと一致するかまで見る
if ! roots=$( cd "$WORK_DIR" && "$FT" doctor --roots-only 2>&1 ); then
  record "ルート解決" fail "$(printf '%s' "$roots" | tr '\n' ' ')"
  print_summary
  echo ""
  echo "❌ ツール本体のルートを解決できません。→ SKILL.md ステップ7.5 の検証ゲートを参照" >&2
  exit 1
fi
# /private/tmp と /tmp(や /private/var と /var)は同じ場所。Foundation の
# resolvingSymlinksInPath は /private を落とし、シェルの pwd は付けるので、
# 突き合わせ前に両側から /private を外す(実測で食い違った)
unprivate() { printf '%s' "$1" | sed 's|^/private/|/|'; }
roots_norm="$(printf '%s' "$roots" | sed 's|/private/|/|g')"
roots_ok=1
printf '%s' "$roots_norm" | grep -qF "$(unprivate "$TOOL_ROOT")" || roots_ok=0
if [ -f "$WORK_DIR/Package.swift" ]; then
  printf '%s' "$roots_norm" | grep -qF "$(unprivate "$WORK_DIR")" || roots_ok=0
fi
if [ "$roots_ok" = "1" ]; then
  record "ルート解決" ok "ツール本体=$TOOL_ROOT / パッケージ=$WORK_DIR"
else
  record "ルート解決" fail "意図と違うルートに解決されました: $(printf '%s' "$roots" | tr '\n' ' ')"
  print_summary
  echo ""
  echo "❌ 別のクローン/パッケージに解決されています(旧 clone の残骸を疑う)。" >&2
  echo "   → SKILL.md ステップ7.5 の検証ゲート・docs/getting-started.md「アンインストール」を参照" >&2
  exit 1
fi

# ---- 2.5 Apple Intelligence(SKILL ステップ2.5・不可でも続行) -----------------
if "$FT" doctor --fm-only >/dev/null 2>&1; then
  record "Apple Intelligence" ok "利用可能"
else
  record "Apple Intelligence" warn "無効/未DL(heal・視覚検証・シナリオ生成のみ影響。後から有効化可)"
fi

# ---- 3. 環境レポート(SKILL ステップ3。ゲートではない) ------------------------
if [ "$DO_DOCTOR" = "1" ]; then
  echo ""
  echo "==> ftester doctor(環境レポート)"
  ( cd "$WORK_DIR" && "$FT" doctor ) || true
fi

# ---- 導入時点の版を記録(判定には使わない。更新が反映されないときの切り分け用) ----------
# 更新チェック本体(Scripts/update-check.sh)は git を直接見るのでこのファイルに依存しない。
# ここに書くのは「いつ・どの版を入れたか」だけ。書けなくてもインストールは成功扱い
if [ -d "$WORK_DIR/.ftester" ]; then
  cat >"$WORK_DIR/.ftester/state.json" 2>/dev/null <<EOF || true
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "toolRoot": "$TOOL_ROOT",
  "toolRootHead": "$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null)",
  "toolRootRef": "$(git -C "$TOOL_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
}
EOF
fi

NEXT_PROFILES=""
case " ${STEPS[*]} " in
  *"プロファイル|ok"*) : ;;
  *) NEXT_PROFILES="・プロファイル(マシン/アプリ/実行)の作成 → Claude Code で /ftester-profiles
" ;;
esac

print_summary

[ "$DO_NEXT_STEPS" = "1" ] && cat <<EOF

──────── 次にやること ────────
${NEXT_PROFILES}・VSCode で $WORK_DIR を開き、Developer: Reload Window(拡張の反映に必須)
・Claude Code が ftester MCP サーバの承認を求めたら許可する(ft_* が使えるようになる)

更新: VSCode 拡張が起動時に自動で確認します(設定 ftester.updateCheck で無効化可)。
      手動で確認 → bash $TOOL_ROOT/Scripts/update-check.sh / 取り込み → /ftester-update
インストールログ: ${LOG_FILE:-(出力できませんでした)}
EOF

if [ "$SOFT_FAILED" = "1" ]; then
  echo ""
  echo "⚠️ 一部の任意ステップが未完了です(上の ⚠️ 行)。CLI と MCP は使えます。"
  exit 2
fi
echo ""
echo "✅ インストール完了"
