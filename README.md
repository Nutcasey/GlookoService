# GlookoService: Loop → Glooko pump history

A reporting-only Loop service. It sends reconciled pump delivery through a **virtual Omnipod Eros reporting device** and carb entries as Glooko foods. It does not upload glucose. It never doses, changes Loop therapy or acts on remote commands.

The insulin importer is a compatibility route, not a native Loop integration. New installations leave insulin reporting off until the user chooses it; carb foods remain independent. Existing installations retain their insulin, password-recovery and cellular settings on upgrade. Any real pump which supplies complete Loop delivery/settings context can use the insulin adapter, but Glooko still assigns the virtual Insulet identity. A generic faithfully attributed pump write API has not yet been integrated.

Glucose upload was removed on 27 October 2026. There is no glucose sender, CSV importer, glucose upload setting or glucose subscription in this service. Old saved flags cannot enable it. Upgrade removes this plugin's retired glucose cache, retaining Loop's original glucose store. Use a separate supported CGM-to-Glooko connection for glucose. Historical records already imported into Glooko are not erased by removing an uploader.

## How it works

- Loop's created/deleted doses are durably staged before the source callback succeeds. Commitment waits for the dose and settings queries to finish; a page boundary is not a complete clinical snapshot.
- History settles for one hour and stops before unresolved mutable doses or a bolus whose end has not settled. Commit boundaries use whole native seconds after all source caps, preserving fractional remainders for the next window. Manual **Upload now** also commits everything ready at that boundary.
- Actual basal delivered volume is retained separately from programmed rate. The encoder uses adjacent native hundredth-unit rates where necessary to preserve volume, rather than rounding away insulin. Genuine gaps are suspensions. Temporary rates cannot expire before the next actual boundary.
- The account is verified before each submission. History and Keychain credentials are partitioned by the patient GUID. Reconnecting the same account resumes its identity and indices; another account receives its own history.
- An upgrade migrates the original history without changing its serial or record indices and retains a legacy backup. Read/decode errors pause uploads instead of creating an empty replacement.
- Schema 4 retains original submitted records and exports inert download markers for the old zero-second suspend/resume bug. Before resending, it corrects affected zero-rate scheduled basals by their existing Glooko GUID, or removes a duplicate zero-rate artefact when the correct row already exists. Every write has a durable before-image and requires readback; unrelated non-zero discrepancies stop recovery.
- Verification defers the interval ending at an in-progress basal until later history finalises that boundary. Wrong values, duplicate rows and missing final records are reported separately. Deferred recent intervals do not freeze confirmation of the final history.
- File acknowledgement and the verified native prefix are persisted separately, so retention cannot prune an interval that still awaits finalisation. Fresh ingestion receives bounded readback retries without resubmitting the file.
- Carbs entered in Loop are sent soon after saving as standalone Glooko foods (listed as "Food"), outside the pump file. Each Loop entry keeps fixed Glooko IDs, so edits update and deletions remove the same entry, and each is confirmed by reading it back.
- Carb identities include their source app. Confirmation covers the complete entry, including edits without a source version. Legacy entries retain their existing remote GUIDs when replayed source history establishes their owner; ambiguous ownership pauses the callback instead of overwriting another entry. Unreadable, corrupt or missing acknowledged carb storage also pauses callbacks and preserves the original file.
- The carb sender drains edits received during a request, retries failures with bounded backoff and is cancelled on service deletion. **Upload now** retries carbs even when pump reporting is paused. Readback follows recent update time, rather than scanning the account's entire food history after every entry.
- Settings come from Loop's saved therapy configuration, including basal programme, carb ratios, sensitivity, target range, safety threshold, maximum doses and insulin action duration. Missing settings block submission. The IBF envelope retains the accepted Eros hardware descriptors for the virtual reporting device; these do not describe the attached pump's hardware.
- Stored pump context identifies the selected real source. Simulator/unknown sources, source changes and intervals spanning source changes pause reporting for review. A timestamp alone does not authorise a source.
- Routine insulin files include yesterday, today and every unconfirmed day, starting only at a real midnight delivery boundary with consistent clock context. Initial uploads, backlogs and unsafe clock/boundary cases use the retained-file fallback. Local 14-day retention remains separate from the posted window. This avoids reposting the whole retained fortnight during normal operation without risking partial-day summaries. Readback checks the submitted window; manual diagnostics still check retained history.
- New installations default to Wi-Fi-only requests; users can enable cellular explicitly. Low Data Mode requests are disabled. Existing installations retain their previous cellular behaviour.
- At most every 15 minutes the file is submitted to `POST https://eu.api.glooko.com/api/v3/device/file/upload?extractorName=InsuletOmnipod`. Authentication redirects are not followed. Session recovery includes HTTP 421 and verifies the patient again.
- **Submission and confirmation are separate.** A source-specific readback checks each eligible final basal, suspension and bolus record, including its quantity/duration. Missing/incomplete readback leaves the file pending. Running intervals are not claimed as confirmed coverage.
- Unconfirmed records are never pruned. Confirmed history is retained for at least 14 days, with its delivery anchor. Indices remain stable across retries and relaunches.

## Corrections and recovery

Backfilled, changed or deleted doses can rebuild the unsubmitted tail while preserving the submitted prefix. A persisted submission checkpoint identifies which source doses and boundary may have reached Glooko. Source changes are reconciled again after authentication, immediately before recording submission intent. Once indices may have reached Glooko, this integration has no verified remote amendment/deletion contract. Those changes are retained as explicit conflicts and uploads pause; they are never silently acknowledged as corrected. A correction which returns to the original submitted value resolves its conflict. Late-dose counts use distinct source identities.

History schema 3 stores source dates losslessly and reads older ISO date formats. Existing identities and indices survive migration. Older builds cannot read the new schema. Loop's host must query restored services on launch, retaining its existing stream anchors, so the service receives fresh dose and settings drain boundaries even without a new settings change.

The standalone host change is [LoopKit/Loop PR #2620](https://github.com/LoopKit/Loop/pull/2620). The [self-contained integration patch and instructions](Documentation/Loop/README.md), based on Loop `7bb17492`, are also included in this public repository. No private checkout is required.

The plugin never deletes or rewrites Loop’s private `RemoteDataServicesManager` query-anchor keys. Normal host add/restore queries own source replay. Very old installations which require legacy carb ownership replay show an explicit migration warning: remove and re-add the service **keeping local history** so Loop supplies its retained cache. This cannot recover source history Loop no longer retains.

The status screen updates as work progresses and shows last submission, last confirmation, confirmed coverage and conflicts. An old mutable marker remains visible with a recovery explanation instead of disappearing or silently holding the queue forever.

Report checks run after confirmed pump ingestion and compare Glooko's Summary with its stored per-device summaries. Device-transition discrepancies, missing automatic labels and a zero current-day summary remain visible separately from successful record ingestion. Carb-only foods are visible in Graphs/History; the website's Diet panel may remain empty for them.

The status screen identifies the GlookoService build by its short commit hash, appending `.dirty` for uncommitted changes, followed by its build date and time. The UI framework captures these values during its build, following Glasshouse's commit/dirty convention. Builds outside a GlookoService Git checkout show `unknown` rather than another repository's hash.

Reconnect to the pump to resolve provisional data first. If a source change or unresolved old history requires a new period, the explicit **Start a new reporting period** action archives the old history and begins from now. It does not amend existing Glooko records. Removal offers **Disconnect and keep history** or a separately confirmed **Erase local data and remove**. Both stop/cancel all owned work and remove the current account’s credentials. Erasure also removes all of this plugin’s account-scoped pump and carb history, archives, legacy backups, diagnostics and associated credentials from this app. It leaves Loop’s original source stores and Glooko’s remote records intact. Deletion errors stay visible so removal can be retried.

## Authentication and Loop alerts

Glooko documents [OAuth 2 with PKCE and refresh tokens](https://developers.glooko.com/docs/oauth/configuration/authorization). It requires a client ID and redirect URI registered by Glooko; dynamic registration is unavailable. This repository has no registered Loop client and does **not** claim to use OAuth. Its compatibility login uses the existing patient-app session cookie.

New sign-ins save the session only. **Remember password for session recovery** is optional and explains that the app can retrieve and replay the password. Session and optional password use `AfterFirstUnlockThisDeviceOnly`, with no iCloud synchronisation or migration to another device. Existing users retain password recovery until they choose **Forget stored password** or change sign-in settings. Account identity is checked before submissions. Concurrent senders share one authentication operation; automatic password attempts are rate-limited. Rejection/restriction statuses (401, 403, 423, 429), MFA and an unavailable recovery secret stop automatic replay and require interactive sign-in. Temporary network errors remain retryable. Raw sign-in bodies, passwords, cookies and transport descriptions are excluded from error output and diagnostics.

The service issues real Loop alerts, with immediate foreground and background content, for authentication requiring attention, history paused for review, eligible submissions overdue, and accepted submissions still unconfirmed. The default delay is one hour, configurable in settings; the clinical one-hour settling window is excluded. Empty or intentionally disabled streams do not produce overdue alerts. Stable IDs deduplicate alerts across relaunches and retract resolved conditions. **Send test alert** exercises the real Loop alert path. Evaluation runs on source/request activity and a 60-second owned wake-up while the host can execute; iOS suspension limits remain and Loop’s own not-running alerts still matter. Password changes/account closure are detected when Glooko rejects or no longer verifies the session, not instantly while a cookie remains valid.

Enabling native Loop identity and OAuth requires Glooko to register Loop, issue application credentials/redirect metadata, and confirm a supported write contract for pump basals, boluses, settings and source identity. This cannot be enabled by changing a manufacturer string or borrowing another application’s credentials.

## Layout and build

| Path | Contents |
|---|---|
| `GlookoKit/` | LoopKit-free client, production IBF writer, durable history/repository and readback verifier |
| `GlookoServiceKit/` | Loop service, source/settings context and dose adapter |
| `GlookoServiceKitUI/` | Cancellable sign-in and live status/recovery screens |
| `GlookoServiceKitPlugin/` | Plugin principal class and discovery metadata |
| `Tests/GlookoKitTests/` | Production-file decoder regressions, history/recovery, account migration and accepted synthetic golden files |
| `Tests/GlookoServiceKitTests/` | Actual iOS adapter, filesystem, Keychain and intercepted URLSession integration regressions |

The core builds/tests on macOS with `swift test`. The iOS plugin builds inside LoopWorkspace:

1. Add this repository to LoopWorkspace, for example as a submodule named `GlookoService`.
2. Add `GlookoService/GlookoService.xcodeproj` to the workspace.
3. Add `GlookoServiceKitPlugin` to the workspace scheme's build action.
4. Build/install Loop normally. Loop's `copy-plugins.sh` embeds the plugin and its frameworks.

After adding source files, run `xcodegen generate` and include the regenerated project with the change.

The service-list icon is Glooko's blue-and-white app artwork from its [official App Store listing](https://apps.apple.com/gb/app/glooko-track-diabetes-data/id471942748), bundled locally in the UI framework's asset catalogue.

The status screen identifies the physical pump and uploader together, for example **Omnipod 5 via Loop**, beside Loop's app icon. After clinical ingestion, or when manually checking an existing reporting device, the service saves that label in the virtual pump's `model` and a namespaced Loop marker in `externalId`. It requires one matching native reporting device, preserves its GUID, serial, manufacturer and catalogue reference, refuses another uploader's identifier, and verifies readback. Label errors are reported independently of clinical confirmation. Glooko's website and reports can continue displaying their catalogue name, **Insulet Omnipod System**; this is metadata attribution, not a new Glooko catalogue integration. The bundled Loop icon is unmodified upstream artwork with its notice in `LoopArtwork-LICENSE.txt`.


Run the `GlookoServiceTests` scheme on an iOS simulator for the service integration suite. Its dedicated application host provides an isolated sandbox and Keychain; every HTTP request is intercepted. Simulator builds need ad hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`) so Xcode supplies the host's simulated Keychain entitlements. Disabling signing produces a host without usable Keychain access. Loop's `RemoteDataServicesManagerTests` separately verifies that restoration queries unchanged source streams.

## Verification and limits

The repair was exercised with offline history replays, two four-day simulations with interrupted/automatic boluses, suspensions, replacements, resends, persistence and simulated failures, and an independent IBF decoder. All checked complete-day basal/bolus totals matched. The suite now includes unsubmitted-tail/checkpoint migration, exact source replay, carb corruption/provenance/revision and reverse-order readback regressions. The iOS suite covers shared password recovery and rejection, authentication interleavings, cancellation, in-flight edits, manual retry, retry without another source event, and no paused-stream alert while a relaunched service's source streams drain normally. Core authentication tests exercise all six host/body combinations through URLSession, terminal rejections, cancellation, provisional MFA cookies, HTML, expired/missing cookies and secret-free errors. Health tests cover alert timing, persistence, deduplication/retraction and plugin-scoped erasure. The rolling-window regression decodes actual exported files, preserves unconfirmed days and checks the clock-context fallback.

A live isolated-account experiment also accepted an overlapping recent-day file while retaining earlier native GUIDs, clinical quantities and all three closed-day insulin totals. The initial complete file was verified before the suffix was submitted.

A revised synthetic file was accepted in the isolated test account and **all 18 eligible final clinical records passed the production readback verifier**. The supplied nondefault maximum doses, insulin duration, carb ratio and sensitivity were also read back from Glooko settings. This establishes the tested file contract; it does not prove every real pump history or clinic report.

Device-record confirmation and Glooko's overall Summary statistics are separate contracts. On a mixed Omnipod 5/Loop day, the captured per-device summaries and individual Loop records reconcile, but the overall statistics omit the Loop device's quantities. The same result persists in fresh, no-cache and two-day-range reads. Delayed server-side statistics recalculation remains possible; its refresh deadline and source-selection rules have not been established. Do not treat a successful record readback as proof that the dashboard has combined both devices.

Remaining format/product limits:

- Automatic boluses/temps appear as ordinary boluses/temps.
- Interrupted boluses retain delivered volume but not their original programmed amount in Glooko's decoded records.
- The previously observed detailed-row discrepancy on clock-change days remains; daily-summary parity was observed in the earlier fixtures. Travel/time-zone reconstruction is limited by source context.
- Bolus amounts use the format's hundredth-unit precision; therapy profiles use the native profile precision.
- Two-factor sign-in and regions outside the EU are unsupported.
- Submitted clinical corrections remain reviewable conflicts until a supported amendment contract is established or the user explicitly archives the period.

## Diagnostics on the phone

Open **Settings → Glooko → Diagnostics and live check**. **Check Glooko now** performs fresh authenticated reads of stored pump history. It compares exact values against a captured copy of Loop's local history and reports missing, different and duplicate records. The check does not send clinical data or advance upload acknowledgements. Results are dated, retained across restarts, and remain separate from Glooko's overall Summary warnings.

The screen also shows dose/settings callback times, query-drain state, pending dose/carb queues, final pump-history cutoff and confirmation dates. Pump history retains its one-hour settling delay and fifteen-minute submission interval.

The service retains up to 250 activity events for at most 48 hours in protected, account-scoped storage. HTTP traces include method, path without query parameters, status, duration and byte counts. Headers, cookies, passwords and bodies are excluded. Journal failures are visible and do not block clinical uploads; an unreadable journal is preserved rather than overwritten. Use the share button to review/export the diagnostic report. It contains health-data timings, counts and errors.

In the Glooko mobile app, use **Daily log** for dose and food entries. This service does not import or verify CGM readings.
