# アプリが依存するサービス(compose.yaml)

[in English](services.md)

テスト対象のアプリが DB・API・スタブサーバなどを必要とするときは、
`TestProjects/<プロジェクト>/workspace/scripts/compose.yaml`(`setup.sh` と同じ `scripts/`)に宣言します。
fleetest が **run ごとにサービスを起動し、終わったら止めます**。起動の完了(`healthcheck`)を待ってから `setup.sh` が走り、
`teardown.sh` の後に止めます。ファイルが無ければ何も起きません。

動くのは `fleetest run`・VS Code 拡張からの実行・MCP の `ft_start_run` です。`ft_run_scenario`(単発)と `--dry-run`
では起動しません。探索のためにサービスを上げておくには `fleetest services up` を使います
([手で起動して止める](#手で起動して止める))。[リモートランナー](../../fleet/remote_runners_ja.md)へ送った run では、
サービスは**ランナー機の上で**(その機械のランタイムと設定で)起動します。

## ランタイム

Docker(Rancher Desktop・Docker Desktop など。unix ソケット経由)か、Apple Container(`container` コマンド)を使います。
固定するには、この Mac の `~/.config/fleetest/config.json` に書きます。

```json
{
  "services": { "runtime": "docker" }
}
```

`runtime` は `"docker"` か `"apple"` です。未設定なら、Docker が使えれば Docker、使えなければ Apple Container を使います
(Apple のシステムサービスを自動で起こすのは、Docker が使えないときだけです)。

## 例

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
    volumes:
      - dbdata:/var/lib/postgresql/data
  api:
    image: example/api:latest
    depends_on:
      db:
        condition: service_healthy
    ports: ["127.0.0.1:8080:8080"]
    environment:
      API_TOKEN: ${API_TOKEN}

volumes:
  dbdata:
```

アプリとシナリオは `api` に `127.0.0.1:8080` で届きます。

## 書けるもの

書き方は compose と同じです。

- `services.<name>` の下: `image` または `build`・`command`・`entrypoint`・`environment`・`env_file`・`ports`・`volumes`・
  `depends_on`(`condition`: `service_started` / `service_healthy` / `service_completed_successfully`)・`healthcheck`・
  `stop_grace_period`・`working_dir`・`user`・`mem_limit`・`cpus`・`tmpfs`・`init`・`platform`・`labels`・`networks`。
- トップレベル: `networks` と `volumes`。`version` と `x-*` は無視します(無視したことを1行知らせます)。
- **書けないもの**: `restart`・`privileged`・`cap_add`・`network_mode`・`extra_hosts`・ホストの任意パスの bind
  (bind できるのは `scripts/` と `data/` の下だけ。`scripts/` は読み取り専用)・外部ネットワーク。知らないキーや型は、
  何が駄目かを名指しして断ります(run は始まりません)。

## 規則

- **コンテナは外部ネットワークへ出られません。** 例外は、この Mac の設定 `sandbox.allowedDomains` に書いたドメインで、
  fleetest のプロキシ経由で出ます(コンテナには `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` が入ります)。
  書き方は[シナリオから外部へ通信する](network_access_ja.md)にあります。
- **公開ポート(`ports`)は `127.0.0.1` だけに束縛します**(実機は下の節)。
- **イメージは、手元に無いときだけ取得します。** 取得はランタイムが直接行うので、初回は外へのネットワークが要ります。
- **`build:`** の context は `scripts/` の下か、この Mac の設定 `"services": {"buildSources": ["<dir>", …]}` に書いた
  場所に置きます(読み取り専用でマウントしてビルドします)。ビルドの入力が変わっていなければ再ビルドしません。
  **Apple Container のビルドは、既定で 2 CPU・メモリ 2 GB のビルダー VM の中で動きます。** Gradle や Maven のビルドは
  そこでは極端に遅くなったり止まったりします。run の前に一度だけ増やしてください:
  `container builder stop && container builder start --cpus 6 --memory 8g`(fleetest は変更しません)。
- **`healthcheck` を書いてください。** 無いと、「起動した」時点で使えるとみなします。
- **`service_completed_successfully` で待たれる側**(初期化のコンテナ)は前面で実行され、終了コードで決着します。
  0 以外なら run は始まりません。
- **名前付きボリュームは run をまたいで残ります。** 消すのは `fleetest services reset` です。
- **起動や healthcheck に失敗すると、run はシナリオを1本も実行せずに止まり**、失敗したサービスのログの末尾を出します。
- **`setup.sh` が失敗したとき・run が赤で終わったときは、各サービスのログの末尾を保存します**(run の結果の
  ディレクトリ `results/runs/<月>/<runID>/services/<service>.log`)。
- **Docker の API を TCP で公開しないでください**(`0.0.0.0:2375` / `2376`)。コンテナがそこへ届くとこの Mac の
  ファイルをマウントできます。その状態ではサービスの起動は断られ、`fleetest doctor` が警告します。

## 秘密

秘密は、この Mac の `~/.config/fleetest/secrets/<プロジェクト>.env` に `KEY=value` の行で置き、compose.yaml の
`environment` の値から `${NAME}` で参照します(参照できるのは `environment` の値だけです)。参照した名前だけが、
`setup.sh` / `teardown.sh` の環境変数にも入ります。値は fleetest の出力(コンソール・ログ)で伏せられます。
シナリオとスクリプトからこのファイルは読めません。

秘密でない変数の置き換えは `scripts/.env` に書きます(同じ `${NAME}` 記法)。

## 実機

実機(物理端末)のレーンを含む run では、この Mac の設定に次が必須です。

```json
{
  "services": { "publishForPhysicalDevices": "<この Mac の LAN の IPv4 アドレス>" }
}
```

無いと run は始まらず、書き方を示すメッセージが出ます。

- **Apple Container** は、その LAN アドレスと `127.0.0.1` の両方に束縛します。**Docker は1つの IP に束縛できないので、
  全インターフェース(0.0.0.0)に公開します。**
- **Android の実機**: 公開した TCP ポートごとに、fleetest が `adb reverse tcp:<port> tcp:<port>` を張ります。端末の
  アプリは `127.0.0.1:<port>` でサービスに届きます。張れなかったときは警告を出します。
- **iOS の実機**: LAN アドレスを焼き込んだビルドを使います([実機を足す](../../fleet/adding_physical_devices_ja.md))。
- **露出の注意**: ポートを LAN に公開している間は、同じ LAN の誰でもそのサービスに届きます。サービス側で認証を
  掛け、公開はその run の間(と `services up --physical` から `down` まで)だけにしてください。

## UDP

`ports` に `/udp` を書くと、起動の後に fleetest が UDP の経路を一度確かめます(エコー、1 秒 × 3 回)。届かなければ
**警告**を出します(run は止めません)。Rancher Desktop のポート転送方式が SSH のときは UDP が通らないので、警告には
その設定名を添えます。run の警告(これと、張れなかった `adb reverse`)は、その run の `run.json` にも
`servicesWarnings` として記録されます。

## レジストリに届かない機械でのイメージ

イメージは無いときにランタイムが取得するので、初回の run はレジストリへの通信が要ります。先に用意しておく・届かない
機械で使うには次を使います。

| コマンド | 内容 |
|---|---|
| `fleetest services pull [--project <p>] [--profile <pf>] [--refresh]` | compose.yaml が宣言するイメージを取得します(初回は fleetest の中継のイメージもビルドします)。何も起動しません。`--refresh` は手元にあっても取り直します |
| `fleetest services load <file>` | `docker save` / `container image save` で作った tar アーカイブのイメージを、この Mac のランタイムへ読み込みます |

## スクリプトからコンテナを操作する

`setup.sh` / `teardown.sh` からコンテナを操作する手段は、中継コマンド `fleetest-services`(PATH にあります)だけです。
対象になるのは、宣言したサービスだけです。

```sh
fleetest-services exec db -- psql -U app < "$FT_WORKSPACE/data/seed.sql"   # 標準入力も渡せる
fleetest-services logs api --tail 100
fleetest-services status
fleetest-services port api 8080            # 公開先の host:port を印字(UDP は /udp)
```

| コマンド | 内容 |
|---|---|
| `fleetest-services exec <service> -- <command…>` | サービスのコンテナの中でコマンドを実行する |
| `fleetest-services logs <service> [--tail N]` | ログを出す |
| `fleetest-services status` | サービスの状態を出す |
| `fleetest-services port <service> <containerPort>[/udp]` | 公開先の `host:port` を出す |

スクリプト自体は自分用のサンドボックスの中で動きます([run の前後で処理を走らせる](extending_ja.md#run-の前後で処理を走らせる))。

## 手で起動して止める

探索・ライブ操作・シナリオ作成のために、run の前にサービスを人が起こせます。

| コマンド | 内容 |
|---|---|
| `fleetest services up [--project <p>] [--profile <pf>] [--physical] [--serial <adb serial>…]` | 起動して**上がるまで待ち**、公開ポートを印字して返ります。サービスはその後も動き続けます(常駐の所有者プロセスが持ちます。ログは `.fleetest/services/<prefix>.log`)。プロジェクトにプロファイルが1つなら `--profile` は省略できます |
| `fleetest services down` | 止めます |
| `fleetest services status` | 控え・ロック・ランタイム上の資源を見ます。名前付きボリュームと、fleetest がビルドしたイメージ(このワークスペースの `build:` と中継のイメージ)は大きさつきで出ます。自動では消さないので、大きくなっていたら `reset` で消します |
| `fleetest services reset [--force]` | このワークスペースのコンテナ・ネットワーク・**ボリューム**・控えを全部消します。run か `up` が握っている間は `--force` が要ります |

**本番の run(`fleetest run` / `ft_start_run`)は、`up` で起こしたサービスを引き取ります。** 警告を出して止め、自分で
起こし直して自分で止めます(結果を再現できる形にするためです)。run が握っている間の `services down` は断られます。

MCP では `ft_services` が同じことをします。`action` は `up` / `down` / `status`、`profile` は `up` / `down` で必須、
`project`・`physical`・`androidSerials`(文字列の配列)は任意です。`ft_start_run` と同じく承認を求めます
([MCP サーバ](../tools/mcp_server_ja.md#サンドボックスと承認))。

## 途中で死んだら

run が片付けられずに死んだとき(ssh の切断・SIGKILL)は、その機械で次に走る run か `fleetest hooks reap` が、控えに
記録した ID でコンテナとネットワークを消します。ランナー機では `fleetest remote clean` を使います。

### Link
- [index](../../index_ja.md)
