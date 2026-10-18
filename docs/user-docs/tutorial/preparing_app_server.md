# Preparing the servers your app depends on

[in Japanese(日本語)](preparing_app_server_ja.md)

The general flow for putting the servers, DBs and stubs your own app uses into containers and declaring them to
fleetest. The details of the specification are in [Services the app depends on](../reference/writing/services.md).
For a worked example with the sample app, see "Preparing the sample app" in the [Quick start](../quick-start.md#4-preparing-the-sample-app).

## The idea

- Servers are declared in `TestProjects/<project>/workspace/scripts/compose.yaml`. fleetest **starts them on every
  run and stops them when it ends**. Every run starts from the same state, and the start-up is waited for with a
  `healthcheck`.
- Do not start servers from a scenario or from `run-setup.sh`. Without a declaration, nothing happens.

## Steps

### 1. Write a Dockerfile

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

### 2. Build the image

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

### 3. Write compose.yaml

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

### 4. Point the app at the server

| Run target | Address of the server as seen from the app |
|---|---|
| iOS Simulator | `127.0.0.1` |
| Android Emulator | `10.0.2.2` |
| Physical device | This Mac's LAN address (the machine setting `services.publishForPhysicalDevices` is also needed) |

### 5. Check it

```bash
../foundation-tester/.build/debug/fleetest services up --profile <run profile>
curl http://127.0.0.1:8080/health     # the published port it printed
../foundation-tester/.build/debug/fleetest services down --profile <run profile>
```

## When you fix the server

Build it again under the same name. fleetest uses the image on this Mac and does not pull it. If you change the name,
change compose.yaml too.

## Asking the AI assistant

When you have a Dockerfile:

```text
Build the image myapp-server:local from the Dockerfile in <server folder> and declare it in TestProjects/project1/workspace/scripts/compose.yaml. The published port is 127.0.0.1:8080. Write a healthcheck. Check that it starts with fleetest services up --profile ios-run, then run services down and report the result.
```

When you have none:

```text
Create a Dockerfile for the server in <server folder>, build the image myapp-server:local from it, and declare it in TestProjects/project1/workspace/scripts/compose.yaml. The published port is 127.0.0.1:8080. Write a healthcheck. Check that it starts with fleetest services up --profile ios-run, then run services down and report the result.
```

## Related

- Secrets (passwords, tokens) go in `~/.config/fleetest/secrets/<project>.env` ([Services the app depends on](../reference/writing/services.md)).
- Containers cannot reach the outside network. Domains to allow go in `sandbox.allowedDomains` ([Network access from scenarios](../reference/writing/network_access.md)).
- Named volumes remain until `fleetest services reset`.
- Use `run-setup.sh` only for seeding data ([Extending](../reference/writing/extending.md)).
- On a Mac that cannot reach the registry, load a tar made on another Mac with `container image save` / `docker save` using `fleetest services load <file>`.

Next: [Creating tests](creating_tests.md)

### Link
- [index](../index.md)
