# HTTP request (httpRequest)

Sends an HTTP(S) request from the scenario, waits for the response and returns it. Use it to prepare test data through
an API or to check server-side state (fleetest's own command).

Scenarios run inside the [sandbox](../../security/sandbox.md), so **the destination must be listed in `allowedDomains`**
(how to write it and what to check when it does not connect: [Network access from scenarios](../writing/network_access.md)).

## Function

```swift
httpRequest(_ url: String, method: String = "GET", headers: [String: String] = [:],
            body: String? = nil, waitSeconds: Double? = nil) -> HTTPResponse
```

| Argument | Description |
|---|---|
| `url` | An `http://` or `https://` URL |
| `method` | The method (case-insensitive) |
| `headers` | Headers to send |
| `body` | The body (a UTF-8 string) |
| `waitSeconds` | How long to wait for the response (seconds). Default 30 (smaller than the 120-second limit of a whole step) |

`HTTPResponse` has:

| Property | Description |
|---|---|
| `status: Int` | The HTTP status code |
| `headers: [String: String]` | Response headers (**names are lower-case**) |
| `data: Data` | The body |
| `text: String` | The body read as UTF-8 (`""` if it cannot be read) |
| `json: Any?` | The body read as JSON (`nil` if it cannot be read) |

```swift
let response = httpRequest("https://api.example.com/orders", method: "POST",
                           headers: ["Content-Type": "application/json", "Authorization": "Bearer \(account("[api].token"))"],
                           body: #"{"item": "widget"}"#)
response.status.thisIs(201)              // the order was created
```

## What counts as a failure

- A bad URL (not `http`/`https`, or no host), a connection error, or no response within `waitSeconds` fails the step and
  aborts the scenario.
- **`4xx` / `5xx` is not a failure.** Check `status` yourself with the [thisIs family](any_value_assertion.md), as in `response.status.thisIs(201)`.
- When the sandbox proxy environment variables are set, the failure text adds that the connection goes through the
  sandbox proxy and hosts not in `allowedDomains` are refused (a pointer on what to check, not a diagnosis).

## Step record

The description is `httpRequest <METHOD> <URL> → <status>` (the body is not recorded). An `account()` value that appears
in the URL is masked as `***` on a Mac where masking is turned on ([Test data and accounts](dataset.md)).

Dry-run sends nothing and returns status 0 with an empty response (the step is still recorded).

When you talk to a server yourself (using `URLSession` directly), use `fleetestURLSession`, which already has the
sandbox proxy configured.

### Link
- [index](../../index.md)
