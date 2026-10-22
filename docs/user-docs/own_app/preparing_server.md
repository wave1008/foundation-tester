# Preparing the servers your app depends on

[in Japanese(日本語)](preparing_server_ja.md)

Put the servers, DBs and stubs your own app (for example the test project myshop) uses into containers and declare them to fleetest.
This is not needed if you only connect to an existing server. How to read the declaration and how to start it are in the [tutorial](../tutorial/preparing_app_server.md) with the sample app.

## 1. Declare the servers and check them

### Prompt for the AI

```text
Build the image myapp-server:local from the Dockerfile in <server folder> and declare it in
TestProjects/myshop/workspace/scripts/compose.yaml of the fleetest test project myshop. If there is no Dockerfile, create one
(split a build stage from a run stage, and include bash in the run stage for the healthcheck). Publish the port on 127.0.0.1:8080. Write a healthcheck.
If you use Apple Container, first set the builder VM to 3 GB of memory.
Make the app's server address switchable in the build settings: http://127.0.0.1:8080 for the iOS Simulator build and http://10.0.2.2:8080 for the Android Emulator build.
Rebuild both and update the paths in the app profile.
Check the start-up with fleetest services up --project myshop --profile ios-run, confirm that /health returns ok, then services down and report the result.
```

## 2. Point the app at the server

The iOS Simulator build points at 127.0.0.1 and the Android Emulator build at 10.0.2.2 (the prompt above includes this).
A physical device points at this Mac's LAN address (the machine setting `services.publishForPhysicalDevices` is also needed;
a worked example is in steps 2-3 of [Measuring the app's responsiveness](../response/measuring_app_response.md)).

## 3. Things you write yourself

Do not have the AI assistant write them.

- Put secrets such as passwords and tokens in `~/.config/fleetest/secrets/<project>.env`.
- Containers cannot reach external networks. Write the domains they may reach in `sandbox.allowedDomains` in the machine settings.

When you fix the server, ask the AI to rebuild the image under the same name.

Related: [Services the app depends on](../reference/writing/services.md) / [Network access from scenarios](../reference/writing/network_access.md) / [Extending](../reference/writing/extending.md)

Next: [Testing an app that needs a login](logging_in.md)

### Link
- [index](../index.md)
