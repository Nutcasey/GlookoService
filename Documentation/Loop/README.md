# Integrate GlookoService with Loop next-dev

`GlookoService/main` targets the async APIs in **Loop and LoopKit next-dev**. It includes the next-dev port and selected-insulin labels. Use `main` for the service; do not select an older completion-handler variant.

This guide covers the plugin’s workspace wiring and the two host behaviours it relies on. It supplements [Loop’s build documentation](https://loopkit.github.io/loopdocs/build/overview/), which covers signing and installation.

## 1. Prepare a matching workspace

For a fresh checkout, use sibling directories:

```sh
git clone --recurse-submodules --branch next-dev https://github.com/LoopKit/LoopWorkspace.git
git clone --branch main https://github.com/Nutcasey/GlookoService.git
cd LoopWorkspace
open LoopWorkspace.xcworkspace
```

Keep LoopKit and the other workspace dependencies aligned with the chosen next-dev workspace. The service imports `LoopUnit`, uses async `RemoteDataService` callbacks and awaits async alert delivery. It does not build against the older completion-handler interface.

For an existing workspace, preserve local changes and check its dependency revisions before switching branches. Do not blindly update or detach every submodule to follow these instructions.

## 2. Include the plugin in the workspace

1. In Xcode, add the sibling `GlookoService/GlookoService.xcodeproj` to **LoopWorkspace.xcworkspace**.
2. Edit the **LoopWorkspace** scheme.
3. In its **Build** action, add **GlookoServiceKitPlugin** and enable it for running/archiving as required.
4. Keep implicit dependency building enabled so the matching LoopKit frameworks are built.
5. Build the **LoopWorkspace** scheme. Loop’s `copy-plugins.sh` embeds the plugin and its frameworks in the app.

The plugin project references the workspace’s LoopKit products; building it alone does not supply those dependencies. No new host app target, entitlement or therapy configuration is required by GlookoService itself.

After installation, verify that **Settings → Add Service → Glooko** exists. A successful compile without plugin discovery is not a complete integration.

## 3. Verify the host startup behaviour

GlookoService waits for finished dose/settings queries and uses stored device metadata to distinguish real delivery from simulator or unknown sources.

### Restored services need source queries

`RemoteDataServicesManager.restoreService` must request existing data after registering the service, just as `addService` does:

```swift
uploadExistingData(to: remoteDataService)
```

This keeps the existing query anchors. It produces drain callbacks even when there is no new source event after launch. Resetting private query-anchor keys inside a plugin is not the solution.

### Store a snapshot after restoring devices

Attach `settingsManager.deviceStatusProvider` before restoring device managers, then store the restored settings snapshot. A previously stored record made before devices were ready can otherwise say no pump is connected.

The service must receive the actual pump identity and recorded insulin selection. Do not work around missing metadata by inventing a manufacturer, serial or real-pump identity in the plugin.

### Included current patch

[next-dev-host-integration.patch](next-dev-host-integration.patch) contains both changes. It was generated and application-checked against Loop commit `415926dd`; its host source was also built for the documented simulator captures. The restored-device snapshot change was verified on a real device with unchanged reported therapy schedules and limits.

Inside the **Loop** checkout:

```sh
git apply --check /path/to/GlookoService/Documentation/Loop/next-dev-host-integration.patch
git apply /path/to/GlookoService/Documentation/Loop/next-dev-host-integration.patch
```

Check your source first. If equivalent changes are already present, do not apply them twice. If another next-dev revision changes the surrounding code, review the two behaviours above rather than forcing the patch.

## 4. Build and check

Choose an existing iPhone simulator or your provisioned phone in Xcode. On the documentation machine, the simulator is named `loop`; no other simulator is required for capture.

A simulator command, run from the **LoopWorkspace** directory, is:

```sh
xcodebuild -workspace LoopWorkspace.xcworkspace \
  -scheme LoopWorkspace -configuration Debug \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath ../Build/GlookoSimulator build
```

Replace `SIMULATOR_UDID` with an existing device from `xcrun simctl list devices available`. Let the workspace choose each target’s SDK; a global SDK override can misdirect its watch targets.

For a phone, use your own signing configuration and follow Loop’s normal installation process. This repository does not provide signing credentials or an account-specific configuration.

After installing:

- Confirm the Glooko service is discoverable and its build is shown on the status page.
- Sign into the intended EU account and choose the reporting period and upload options.
- Check **Diagnostics and live check** for both source queries finishing.
- Restart Loop and check that source identity and query completion recover without changing therapy settings.
- Compare actual eligible entries with Glooko; zero confirmed entries cannot establish clinical upload success.

The pump simulator is deliberately excluded from insulin uploads. It can demonstrate the UI and carb workflow, but it cannot establish real-pump delivery reporting.

## Historical dev patch

`restore-service-queries.patch` is retained as a historical patch for Loop `7bb17492` on **dev**, associated with [LoopKit/Loop PR #2620](https://github.com/LoopKit/Loop/pull/2620). Its test service uses completion handlers. **Do not apply it as the current next-dev installation patch.**

For current behaviour, use the guide and `next-dev-host-integration.patch` above.
