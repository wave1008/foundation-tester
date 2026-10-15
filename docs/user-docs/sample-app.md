# Preparing the Sample App

[in Japanese(日本語)](sample-app_ja.md)

After [Getting Started (Installation)](getting-started.md), this page takes you through pulling the server image of the
sample app used in the Quick start
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile), a Compose Multiplatform shopping app) and
declaring it to fleetest. The server is built with Kotlin (Ktor) and PostgreSQL.

## 1. Pull the server image

### Prompt for the AI

```text
Clone https://github.com/wave1008/sut-ec-mobile next to this folder.
Use Apple Container as the container runtime. If it is missing, install it with Homebrew and run container system start --enable-kernel-install once.
Run container image pull ghcr.io/wave1008/sut-ec-mobile-server:latest and container image pull postgres:16-alpine.
Don't modify any shell configuration files. There's no need to build the app.
Check that container image ls lists sut-ec-mobile-server and postgres, report, and stop.
```

- The server uses an image published on GitHub Container Registry (GHCR), so there is nothing to build on your Mac.
- The cloned repository is used to build the app in the [Quick start](quick-start.md).

<details>
<summary><b>Do it manually (click to show details)</b></summary>

```bash
brew install container
container system start --enable-kernel-install    # fetches the Linux kernel; once only

cd ..                                              # clone next to your work folder
git clone https://github.com/wave1008/sut-ec-mobile.git

container image pull ghcr.io/wave1008/sut-ec-mobile-server:latest
container image pull postgres:16-alpine
container image ls
```

</details>

## 2. Declare the server to fleetest

Servers are declared in `TestProjects/<project>/workspace/scripts/compose.yaml`.

### Prompt for the AI

````text
Create TestProjects/project1/workspace/scripts/compose.yaml with the following content (create the folder if it does not exist; if the test project project1 does not exist, first create it with fleetest project create project1). Report the path of the file you created and stop.

```yaml
# Backend of sut-ec-mobile (PostgreSQL + server). fleetest starts it on every run, waits for the healthchecks, runs the scenarios, then stops it.
# server is the image published on GHCR (fleetest pulls it if it is not on this Mac).
# The app's endpoint is baked into the build (iOS Simulator = 127.0.0.1:8090 / Android Emulator = 10.0.2.2:8090).
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: sutec
      POSTGRES_USER: sutec
      POSTGRES_PASSWORD: sutec
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sutec"]
      interval: 500ms
      timeout: 3s
      retries: 120

  server:
    image: ghcr.io/wave1008/sut-ec-mobile-server:latest
    # The server waits until it can connect to the DB, so it starts right after the DB without waiting for its healthcheck
    depends_on:
      db:
        condition: service_started
    environment:
      DATABASE_URL: jdbc:postgresql://db:5432/sutec
      DB_USER: sutec
      DB_PASSWORD: sutec
      JWT_SECRET: dev-secret-change-me
      IMAGES_DIR: /app/mock-server/images
    ports:
      - "127.0.0.1:8090:8090"
    healthcheck:
      # The image is Alpine without bash or curl, so read /health with BusyBox's wget
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8090/health | grep -q '\"status\":\"ok\"'"]
      interval: 500ms
      timeout: 5s
      retries: 360
      start_period: 10s
```
````

- fleetest starts and stops the server on every run. Even after you restart your Mac, there is nothing to start again.
- The DB is created empty on every run, and the server seeds the initial data at startup.
- To pick up a newer server, run `fleetest services pull --refresh` in your work folder (fleetest keeps using the image already on this Mac).
- See [Services the app depends on](reference/writing/services.md) for how to write the declaration.

<details>
<summary><b>Do it manually (click to show details)</b></summary>

In your work folder, create the folder and write the file:

```bash
mkdir -p TestProjects/project1/workspace/scripts
```

Write the YAML from the prompt above to `TestProjects/project1/workspace/scripts/compose.yaml`.
If the test project `project1` does not exist, first create it with `../foundation-tester/.build/debug/fleetest project create project1`
(the VSCode extension also creates it on startup after Reload Window).

</details>

Next: [Quick start](quick-start.md)

### Link
- [index](index.md)
- [Getting Started (Installation)](getting-started.md)
- [Quick start](quick-start.md)
