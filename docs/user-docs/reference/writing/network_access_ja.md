# シナリオから外部へ通信する

シナリオは[サンドボックス](../tools/mcp_server_ja.md)の中で動くので、**既定では Mac の外へは一切通信できません**。
テストデータを API で用意する・Web の管理画面から値を取るなど、シナリオから外部へ通信したいときは、
宛先を許可してからプロキシ経由で繋ぎます。

## 宛先を許可する

シナリオを実行する Mac の `~/.config/fleetest/config.json` に、`sandbox.allowedDomains` を書きます
(別の Mac で実行するときは、その Mac の設定が使われます)。プロジェクトの中には置けません。

```json
{
  "sandbox": {
    "allowedDomains": ["api.example.com", "*.example.org"]
  }
}
```

| 書き方 | 通る宛先 |
|---|---|
| `api.example.com` | `api.example.com` だけ(完全一致) |
| `*.example.org` | `a.example.org`・`a.b.example.org` などのサブドメイン。**`example.org` そのものは含みません**(要るなら並べて書きます) |
| `203.0.113.10` | その IP アドレスを直接書いた宛先(文字列として一致したときだけ) |

- 大文字・小文字の違いと末尾のドットは区別しません。ポートでは絞りません(許可したホストならどのポートにも繋がります)。
- `*` だけ・途中のワイルドカード(`api.*.com`)のような「全部通す」書き方はできません。書けない形や知らないキー、
  壊れた JSON があると、シナリオを起動せずにエラーで止まります。
- 設定は次のシナリオの起動から効きます。

## 繋ぐ

許可した宛先があると、シナリオには環境変数 `HTTPS_PROXY` / `HTTP_PROXY`(小文字の綴りと `ALL_PROXY` も)で
プロキシの場所が渡ります。通るのは **HTTPS と平文の HTTP だけ**です(それ以外の TCP には繋がりません)。

**`URLSession` はこの環境変数を読みません。**そのままでは許可した宛先にも繋がらないので、プロキシを
`connectionProxyDictionary` に渡します。

```swift
import Foundation

/// サンドボックスのプロキシを使う URLSession。プロキシが無いとき(サンドボックスを外した Mac)は普通に繋ぐ
func sandboxSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    if let proxy = ProcessInfo.processInfo.environment["HTTPS_PROXY"],
       let url = URLComponents(string: proxy), let host = url.host, let port = url.port {
        config.connectionProxyDictionary = [
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
        ]
    }
    return URLSession(configuration: config)
}
```

環境変数のプロキシを読むクライアント(`curl` や、環境変数を読む HTTP ライブラリ)は、何もしなくてもプロキシ経由になります。

## 繋がらないとき

| 起きること | 理由 |
|---|---|
| `URLSession` で接続できない・タイムアウトする | プロキシを渡していない(上の `connectionProxyDictionary`)か、`allowedDomains` を書いていない |
| プロキシが `403 Forbidden` を返す(本文 `fleetest sandbox: <host> is not in allowedDomains …`) | 宛先が `allowedDomains` に一致しない。`*.example.org` は `example.org` に一致しない点に注意 |
| プロキシが `502 Bad Gateway` を返す | 宛先は許可されているが、Mac からその宛先へ繋がらない |
| HTTP 以外の接続(DB への直接接続など)が失敗する | プロキシは HTTPS と HTTP しか通さない |

この Mac の localhost で動くサービスには、許可しなくても繋がります。その範囲と注意点は
[MCP サーバ](../tools/mcp_server_ja.md)のサンドボックスの節を見てください。

### Link
- [index](../../index_ja.md)
