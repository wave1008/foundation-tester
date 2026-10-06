# Network access from scenarios

Scenarios run inside a [sandbox](../tools/mcp_server.md), so **by default they cannot reach anything outside the
Mac**. When a scenario needs the network — preparing test data through an API, reading a value from a web admin
page, and so on — allow the destination first and then connect through the proxy.

## Allowing destinations

Add `sandbox.allowedDomains` to `~/.config/fleetest/config.json` on the Mac that runs the scenarios (when you run on
another Mac, that Mac's settings apply). It cannot be placed inside the project.

```json
{
  "sandbox": {
    "allowedDomains": ["api.example.com", "*.example.org"]
  }
}
```

| Entry | Destinations it allows |
|---|---|
| `api.example.com` | `api.example.com` only (exact match) |
| `*.example.org` | Subdomains such as `a.example.org` and `a.b.example.org`. **Not `example.org` itself** (list it too if you need it) |
| `203.0.113.10` | Requests addressed to that literal IP address (matched as a string) |

- Case and a trailing dot are ignored. Ports are not restricted (any port of an allowed host is reachable).
- Entries that would allow everything, such as `*` alone or a wildcard in the middle (`api.*.com`), are rejected.
  An invalid entry, an unknown key or broken JSON stops the run with an error before any scenario starts.
- The setting takes effect from the next scenario launch.

## Connecting

When any destination is allowed, the scenario receives the proxy location in `HTTPS_PROXY` / `HTTP_PROXY` (also the
lowercase spellings and `ALL_PROXY`). **Only HTTPS and plain HTTP** go through (other TCP connections do not).

**`URLSession` does not read these environment variables.** As is, it cannot reach even allowed destinations, so
pass the proxy in `connectionProxyDictionary`.

```swift
import Foundation

/// A URLSession that uses the sandbox proxy. Without a proxy (sandbox turned off on this Mac) it connects directly
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

Clients that read proxy environment variables (`curl`, HTTP libraries that honor them) use the proxy with no extra
code.

## When it does not connect

| Symptom | Reason |
|---|---|
| `URLSession` cannot connect or times out | The proxy is not passed (the `connectionProxyDictionary` above), or `allowedDomains` is not set |
| The proxy answers `403 Forbidden` (body `fleetest sandbox: <host> is not in allowedDomains …`) | The destination does not match `allowedDomains`. Note that `*.example.org` does not match `example.org` |
| The proxy answers `502 Bad Gateway` | The destination is allowed but cannot be reached from the Mac |
| A non-HTTP connection (e.g. directly to a database) fails | The proxy only carries HTTPS and HTTP |

Services running on this Mac's localhost are reachable without allowing them. For what that covers and what to
watch out for, see the sandbox section of [MCP server](../tools/mcp_server.md).

### Link
- [index](../../index.md)
