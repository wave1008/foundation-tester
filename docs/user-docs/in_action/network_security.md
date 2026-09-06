# Network Exposure and Security

A summary for explaining to IT/security what this tool opens and where, when running on a
corporate LAN that does not reach the internet. It is not a setup guide.

## What listens where

| What | Where it listens | Authentication |
|---|---|---|
| Your Mac (CLI, MCP server, monitor, live control) | **Opens no port at all.** Everything is NDJSON over standard input/output between parent and child processes only | — |
| iOS Simulator bridge (XCUITest / in-app) | `127.0.0.1` inside the device only. The Simulator shares its host's network stack, so your machine can reach it | Not needed (loopback) |
| Android bridge (physical device and emulator alike) | **Loopback inside the device only.** Reached from your machine through a dynamic local port that `adb forward` opens | Not needed (loopback) |
| Android emulator gRPC | `127.0.0.1` | A Bearer token the emulator itself issues once per boot |
| **Physical iPhone, USB path (default, recommended)** | An iproxy (libimobiledevice) USB tunnel. **Stays entirely on loopback** | Not needed (loopback) |
| **Physical iPhone, LAN path** | **All of the device's network interfaces.** Reachable from the same LAN | **Token required** (see below) |

- The bridge uses **32 ports, 8123-8154** (iOS).
- **Two conditions make a physical iPhone fall back to the LAN path**: (1) the Mac does not have
  iproxy installed, or (2) the device is connected over Wi-Fi rather than USB. Either one is
  enough to switch to LAN automatically.
- **The in-app bridge is never bundled into a production build.** It is injected at launch via
  `DYLD_INSERT_LIBRARIES` and is not linked into the app's binary.

## Token authentication for the LAN path (bridge protocol version 91+)

- Each time the bridge starts, the host generates a **32-byte random value** and passes it to the
  test runner as an environment variable.
- Every request from your machine carries it in an `X-FT-Token` header. **A mismatch returns
  401** without touching the device at all. The comparison is constant-time.
- **The bridge cannot open on all interfaces without a token** — the runner refuses to start if
  one is missing.
- The token lives in `<project>/.fleetest/bridge-<port>.endpoint` and **never passes through
  arguments or environment variables to other processes** (so it does not show up in `ps`).
- **This protects against a third party on the same LAN.** The loopback path has no
  authentication at all — anyone who can log into that Mac already has equivalent access.

## Outbound traffic

- **No telemetry or analytics is ever sent** — there is not a single external URL in the product
  code.
- The only outbound traffic is **HTTPS to GitHub**, during setup and update (`git clone`,
  `git ls-remote`, fetching the bootstrap script). **A fully closed network needs an internal
  mirror.**
- Apple Intelligence (Foundation Models) runs **entirely on-device**. Nothing leaves the device.
- **The app under test is never sent to Google.** Android's `adb install` can otherwise be
  blocked indefinitely by a Play Protect prompt, so verification is turned off only for the
  duration of the install and always restored afterward.

## Remote runners (dispatching to another Mac)

- The only path is **SSH with key-based authentication**. No password prompt is used, and
  **relaxed host-key checking is never used**.
- Every argument sent to the runner is quoted.
- **Trust model**: the runner machine itself is trusted (SSH access already means it can execute
  arbitrary code as that user). What comes back from the runner, however, is treated as external
  input.
- The runner ends up holding keys, sources, scenarios, reports, and **recordings**.
  **Recordings and screenshots can show credentials typed during a test.** In a shared lab other
  users can read them too, so do not put production credentials in scenarios or profiles.
- Reachability across routers, firewalls, and access-point client isolation is covered on the
  separate [Remote Runners](remote_runners.md) page — not repeated here.

## Decisions to make operationally

1. **Install `brew install libimobiledevice` on every Mac that uses a physical iPhone.** This
   switches it to the USB tunnel and removes the LAN exposure entirely. It is also the
   recommended default for another reason: a measured round trip drops from about 48ms to about
   5ms, making physical-device scenarios roughly 25% faster.
2. If a Wi-Fi-connected physical device must be used anyway, **put the test devices and runner
   machines on a segregated VLAN.**
3. On a closed network, set up an **internal GitHub mirror** — without it, neither setup nor
   updates work.
4. **Never write production credentials into scenarios or profiles.**

### Link
- [index](../index.md)
