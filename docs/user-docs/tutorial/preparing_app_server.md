# Preparing the servers your app depends on

[in Japanese(日本語)](preparing_app_server_ja.md)

The steps for putting the servers, DBs and stubs your own app uses into containers and declaring them to fleetest.
Writing the Dockerfile and compose.yaml and building the image can be left to the AI assistant. The details of the
specification are in [Services the app depends on](../reference/writing/services.md); for a worked example, see
[sut-ec-mobile/fleetest/compose.yaml](https://github.com/wave1008/sut-ec-mobile/blob/main/fleetest/compose.yaml)
(the server declaration of the sample app used in the [Quick start](../quick-start.md)).

## The idea

- Servers are declared in `TestProjects/<project>/workspace/scripts/compose.yaml`. fleetest **starts them on every
  run and stops them when it ends**. Every run starts from the same state, and the start-up is waited for with a
  `healthcheck`.
- Do not start servers from a scenario or from `run-setup.sh`. Without a declaration, nothing happens.
- A container runtime (Apple Container or Docker) must be installed on the Mac (how one is chosen is in
  [Services the app depends on](../reference/writing/services.md)).

## Steps

### 1. Write a Dockerfile

Put a Dockerfile in the folder that holds the server's source. If there already is one, go to step 2.

#### Prompt for the AI

```text
Create a Dockerfile for the server in <server folder>. Split a build stage from a run stage so the run image stays small.
Include bash in the run stage for the healthcheck.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

Splitting a build stage from a run stage keeps the run image small.

```dockerfile
FROM gradle:8-jdk17 AS build
WORKDIR /src
COPY . .
RUN gradle --no-daemon installDist

FROM eclipse-temurin:17-jre
COPY --from=build /src/build/install/app /app
EXPOSE 8080
CMD ["/app/bin/app"]
```

For an image without the `curl` a `healthcheck` would use, read the endpoint with bash's `/dev/tcp`
(for example `test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q ok <&3"]`).

</details>
<br>

### 2. Build the image

#### Prompt for the AI

```text
Build the image myapp-server:local from the Dockerfile in <server folder>. If Apple Container is used, set the builder VM to 3 GB of memory first.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

With Apple Container, decide the size of the builder VM first. The default 2 GB can stall a build, so start from
3 GB. CPUs are a quarter of the Mac's core count (`sysctl -n hw.ncpu`), rounded up.

```bash
container builder stop && container builder start --cpus <N> --memory 3g
container build -t myapp-server:local .
```

If the build stalls (fails after a long time without output), increase the memory. With Docker it is one line:

```bash
docker build -t myapp-server:local .
```

</details>
<br>

What you see: `myapp-server:local` appears in `container image list` (`docker images` with Docker).

### 3. Write compose.yaml

#### Prompt for the AI

```text
Declare the server image myapp-server:local and PostgreSQL in TestProjects/project1/workspace/scripts/compose.yaml.
The published port is 127.0.0.1:8080. Write a healthcheck for both, and start the server only after the DB is healthy.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: dev
      # An Apple Container volume has lost+found at its root, so use a subdirectory
      PGDATA: /var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
  server:
    image: myapp-server:local
    depends_on:
      db:
        condition: service_healthy
    ports: ["127.0.0.1:8080:8080"]
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q ok <&3"]
      interval: 3s
      retries: 60
```

Published ports are bound to `127.0.0.1` only. Add `condition: service_healthy` to the `depends_on` that waits for a
DB. For a PostgreSQL volume example, see [Services the app depends on](../reference/writing/services.md).

</details>
<br>

### 4. Point the app at the server

Match the app's server address to where it runs. If the address can be switched in the build settings, the Simulator
and Emulator builds come from the same source.

| Run target | Address of the server as seen from the app |
|---|---|
| iOS Simulator | `127.0.0.1` |
| Android Emulator | `10.0.2.2` |
| Physical device | This Mac's LAN address (the machine setting `services.publishForPhysicalDevices` is also needed; steps 2 and 3 of [Measuring app responsiveness](../response/measuring_app_response.md) show an example) |

#### Prompt for the AI

```text
Make My Shop's server address switchable in the build settings: http://127.0.0.1:8080 for the iOS Simulator build and http://10.0.2.2:8080 for the Android Emulator build. Rebuild both and update the paths in the app profile.
```

### 5. Check it

#### Prompt for the AI

```text
Start the servers with fleetest services up --profile ios-run and check that /health returns ok. Then run services down.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest services up --profile <run profile>
curl http://127.0.0.1:8080/health     # the published port it printed
../foundation-tester/.build/debug/fleetest services down --profile <run profile>
```

</details>
<br>

What you see: `services up` prints the published port and returns once the `healthcheck` passes. From then on, every
`fleetest run` starts the servers automatically and stops them at the end.

## Asking for all of it at once

Steps 1 to 3 and 5 can be one request.

When you have a Dockerfile:

```text
Build the image myapp-server:local from the Dockerfile in <server folder> and declare it in TestProjects/project1/workspace/scripts/compose.yaml. The published port is 127.0.0.1:8080. Write a healthcheck. Check that it starts with fleetest services up --profile ios-run, then run services down and report the result.
```

When you have none:

```text
Create a Dockerfile for the server in <server folder>, build the image myapp-server:local from it, and declare it in TestProjects/project1/workspace/scripts/compose.yaml. The published port is 127.0.0.1:8080. Write a healthcheck. Check that it starts with fleetest services up --profile ios-run, then run services down and report the result.
```

## When you fix the server

Build it again under the same name. fleetest uses the image on this Mac and does not pull it. If you change the name,
change compose.yaml too.

```text
I fixed the server. Rebuild the image myapp-server:local from <server folder> under the same name.
```

## Related

- Secrets (passwords, tokens) go in `~/.config/fleetest/secrets/<project>.env` ([Services the app depends on](../reference/writing/services.md)).
  A person on this Mac writes that file by hand.
- Containers cannot reach the outside network. Domains to allow go in `sandbox.allowedDomains` ([Network access from scenarios](../reference/writing/network_access.md)).
- Named volumes remain until `fleetest services reset`.
- Use `run-setup.sh` only for seeding data ([Extending](../reference/writing/extending.md)).
- On a Mac that cannot reach the registry, load a tar made on another Mac with `container image save` / `docker save` using `fleetest services load <file>`.

Next: [Creating tests](creating_tests.md)

### Link
- [index](../index.md)
