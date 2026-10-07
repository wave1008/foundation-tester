# Network access from scenarios

Scenarios run inside a [sandbox](../../security/sandbox.md), so **by default they cannot reach anything outside the
Mac**. When a scenario needs the network — preparing test data through an API, reading a value from a web admin
page, and so on — allow the destination first and then connect through the proxy.

## Allowing destinations

Add `sandbox.allowedDomains` to `~/.config/fleetest/config.json` on the Mac that runs the scenarios (when you run on
another Mac, that Mac's settings apply). It cannot be placed inside the project.

```json
{
  "sandbox": {
    "allowedDomains": ["api.example.com:443", "*.example.org", "[2001:db8::1]:8443"]
  }
}
```

| Entry | Destinations it allows |
|---|---|
| `api.example.com` | `api.example.com` only (exact match) |
| `*.example.org` | Subdomains such as `a.example.org` and `a.b.example.org`. **Not `example.org` itself** (list it too if you need it) |
| `203.0.113.10` | Requests addressed to that literal IP address (matched as a string) |
| `api.example.com:443` | Port 443 of that host only |
| `[2001:db8::1]:8443` | Put an IPv6 address in brackets to give it a port (written without brackets, such as `2001:db8::1`, it allows every port) |

- **An entry without a port allows every port of that host.** The proxy relays TCP without looking at it, so other
  services on the same host (a database, for example) are reachable too. If you know the port, write it.
- One port per entry. To allow several ports, list one entry per port (ranges such as `443-8443` are not accepted).
- Case and a trailing dot are ignored.
- Entries that would allow everything, such as `*` alone, a wildcard in the middle (`api.*.com`) or `:*`, are
  rejected. An invalid entry, an unknown key or broken JSON stops the run with an error before any scenario starts.
- The setting takes effect from the next scenario launch.

## Connecting

When any destination is allowed, the scenario receives the proxy location in `HTTPS_PROXY` / `HTTP_PROXY` (also the
lowercase spellings and `ALL_PROXY`). **Connections that do not go through the proxy cannot reach even allowed
destinations.** The proxy accepts HTTPS (`CONNECT`) and plain HTTP. `CONNECT` relays TCP without looking at it, so
any client that can send `CONNECT` reaches the allowed hosts and ports even with a non-HTTP protocol.

**`URLSession` does not read these environment variables.** A `URLSession` you create yourself cannot reach even
allowed destinations unless you pass the proxy in `connectionProxyDictionary`. Use `httpRequest` or
`fleetestURLSession`, which do that for you.

```swift
let response = httpRequest("https://api.example.com/health")   // goes through the proxy
```

[`httpRequest`](../commands/http_request.md) sends a request and returns the response. To talk to a server yourself, use
`fleetestURLSession` — a `URLSession` with the sandbox proxy already set in `connectionProxyDictionary` (it connects
directly when there is no proxy, e.g. the sandbox is turned off on this Mac).

Clients that read proxy environment variables (`curl`, HTTP libraries that honor them) use the proxy with no extra
code.

## When it does not connect

| Symptom | Reason |
|---|---|
| `URLSession` cannot connect or times out | You use your own `URLSession` without passing the proxy (use `httpRequest` / `fleetestURLSession`), or `allowedDomains` is not set |
| The proxy answers `403 Forbidden` (body `fleetest sandbox: <host>:<port> is not in allowedDomains …`) | The destination does not match `allowedDomains`. Note that `*.example.org` does not match `example.org`, and an entry with a port matches only that port |
| The proxy answers `502 Bad Gateway` | The destination is allowed but cannot be reached from the Mac |
| A non-HTTP connection (e.g. directly to a database) fails | It does not go through the proxy (the client cannot send `CONNECT`), or its port is not allowed |

Services running on this Mac's localhost are reachable without allowing them. For what that covers and what to
watch out for, see [Notes and limitations](../../security/limitations.md).

### Link
- [index](../../index.md)
