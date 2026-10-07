# HTTP リクエスト(httpRequest)

[in English](http_request.md)

シナリオから HTTP(S) のリクエストを送り、応答を待って返します。テストデータを API で用意する・サーバ側の状態を確かめる、
といった用途です(fleetest 独自のコマンドです)。

シナリオは[サンドボックス](../../security/sandbox_ja.md)の中で動くので、**宛先を `allowedDomains` に書いておく必要があります**
(書き方と繋がらないときの見方は[シナリオから外部へ通信する](../writing/network_access_ja.md))。

## 関数

| 関数 | 説明 |
|---|---|
| `httpRequest(url, method:, headers:, body:, waitSeconds:)` | HTTP(S) のリクエストを送り、応答を待って `HTTPResponse` を返します。`method` の既定は `"GET"`、`headers` の既定は空です。 |

宣言:

```swift
httpRequest(_ url: String, method: String = "GET", headers: [String: String] = [:],
            body: String? = nil, waitSeconds: Double? = nil) -> HTTPResponse
```

| 引数 | 説明 |
|---|---|
| `url` | `http://` か `https://` の URL |
| `method` | メソッド(大文字小文字は問いません) |
| `headers` | 送るヘッダ |
| `body` | 本文(UTF-8 の文字列) |
| `waitSeconds` | 応答を待つ上限(秒)。省略時は 30 秒(ステップ全体の締切 120 秒より小さい値) |

`HTTPResponse` の中身:

| プロパティ | 説明 |
|---|---|
| `status: Int` | HTTP のステータスコード |
| `headers: [String: String]` | 応答ヘッダ(**名前は小文字**) |
| `data: Data` | 本文 |
| `text: String` | 本文を UTF-8 として読んだ文字列(読めなければ `""`) |
| `json: Any?` | 本文を JSON として読んだもの(読めなければ `nil`) |

```swift
let response = httpRequest("https://api.example.com/orders", method: "POST",
                           headers: ["Content-Type": "application/json", "Authorization": "Bearer \(account("[api].token"))"],
                           body: #"{"item": "widget"}"#)
response.status.thisIs(201)              // 注文が作られた
```

## 失敗とみなす場合

- URL が不正(`http`/`https` でない・ホストが無い)・通信に失敗した・`waitSeconds` 内に応答が無かった場合は、
  そのステップを失敗にしてシナリオを中断します。
- **`4xx` / `5xx` は失敗にしません**。`response.status.thisIs(201)` のように [thisIs 系](any_value_assertion_ja.md) で `status` を検証してください。
- プロキシ(サンドボックス)の環境変数があるときは、失敗文に「接続はサンドボックスのプロキシを通る・`allowedDomains` に無い
  ホストは断られる」と添えます(原因の断定ではなく、確認する場所の案内です)。

## ステップの記録

説明は `httpRequest <メソッド> <URL> → <ステータス>` です(本文は載せません)。`account()` の値が URL に含まれていれば、
伏せ字化を有効にした Mac では `***` に伏せられます([テストデータ・アカウント](dataset_ja.md))。

dry-run では何も送らず、ステータス 0・空の応答を返します(ステップは記録します)。

自分で通信するとき(`URLSession` を直接使うとき)は、サンドボックスのプロキシを設定済みの `fleetestURLSession` を使ってください。

### Link
- [index](../../index_ja.md)
