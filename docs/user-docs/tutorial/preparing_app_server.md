# Checking the server

[in Japanese(日本語)](preparing_app_server_ja.md)

The SUT Store server (a server plus PostgreSQL) was already declared to fleetest in the Quick Start. Declared servers
start automatically on every `fleetest run` and stop when it ends. The details are in
[Services the app depends on](../reference/writing/services.md).

## 1. Look at the declaration

### Prompt for the AI

```text
Read TestProjects/project1/workspace/scripts/compose.yaml of the fleetest test project project1 and explain
which servers are declared and where the app connects to them (for the iOS Simulator and the Android Emulator separately).
Don't change the file.
```

Expected result:

- The explanation names two declared services (the server and PostgreSQL).
- It says the app connects to 127.0.0.1:8090 on the iOS Simulator and 10.0.2.2:8090 on the Android Emulator.

## 2. Start it and check

### Prompt for the AI

```text
Start the server with fleetest services up --project project1 --profile ios-run and confirm that /health on the published port returns ok.
When confirmed, run services down and report the result.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest services up --project project1 --profile ios-run
curl http://127.0.0.1:8090/health     # at the published port that was printed
../foundation-tester/.build/debug/fleetest services down --project project1 --profile ios-run
```

</details>
<br>

Expected result:

- `services up` prints the published port and returns after the `healthcheck` passes.
- `/health` returns `{"status":"ok","db":"up"}`.

Related:

- [Services the app depends on](../reference/writing/services.md)
- [Network access from scenarios](../reference/writing/network_access.md)
- [Extending](../reference/writing/extending.md)

Next: [Creating tests](creating_tests.md)

### Link
- [index](../index.md)
