# GlookoService: Loop → Glooko pump history

A reporting-only Loop service. It sends reconciled pump delivery to a Glooko account as a **virtual Omnipod Eros reporting device**. It never doses, changes Loop therapy or acts on remote commands.

## How it works

- Loop's created/deleted doses are durably staged before the source callback succeeds. Commitment waits for the dose and settings queries to finish; a page boundary is not a complete clinical snapshot.
- History settles for one hour and stops before unresolved mutable doses or a bolus whose end has not settled. Manual **Upload now** also commits everything ready at that boundary.
- Actual basal delivered volume is retained separately from programmed rate. The encoder uses adjacent native hundredth-unit rates where necessary to preserve volume, rather than rounding away insulin. Genuine gaps are suspensions. Temporary rates cannot expire before the next actual boundary.
- The account is verified before each submission. History and Keychain credentials are partitioned by the patient GUID. Reconnecting the same account resumes its identity and indices; another account receives its own history.
- An upgrade migrates the original history without changing its serial or record indices and retains a legacy backup. Read/decode errors pause uploads instead of creating an empty replacement.
- Carbs entered in Loop are sent soon after saving as standalone Glooko foods (listed as "Food"), outside the pump file. Each Loop entry keeps fixed Glooko IDs, so edits update and deletions remove the same entry, and each is confirmed by reading it back.
- Settings come from Loop's saved therapy configuration, including basal programme, carb ratios, sensitivity, target range, safety threshold, maximum doses and insulin action duration. Missing settings block submission. The IBF envelope retains the accepted Eros hardware descriptors for the virtual reporting device; these do not describe the attached pump's hardware.
- Stored pump context identifies the selected real source. Simulator/unknown sources, source changes and intervals spanning source changes pause reporting for review. A timestamp alone does not authorise a source.
- At most every 15 minutes the file is submitted to `POST https://eu.api.glooko.com/api/v3/device/file/upload?extractorName=InsuletOmnipod`. Authentication redirects are not followed. Session recovery includes HTTP 421 and verifies the patient again.
- **Submission and confirmation are separate.** A source-specific readback checks each eligible final basal, suspension and bolus record, including its quantity/duration. Missing/incomplete readback leaves the file pending. Running intervals are not claimed as confirmed coverage.
- Unconfirmed records are never pruned. Confirmed history is retained for at least 14 days, with its delivery anchor. Indices remain stable across retries and relaunches.

## Corrections and recovery

Before any possible submission, backfilled, changed or deleted doses can rebuild the local history safely. Once indices may have reached Glooko, this integration has no verified remote amendment/deletion contract. Those changes are retained as explicit conflicts and uploads pause; they are never silently acknowledged as corrected. Late-dose counts use distinct source identities.

The status screen updates as work progresses and shows last submission, last confirmation, confirmed coverage and conflicts. An old mutable marker remains visible with a recovery explanation instead of disappearing or silently holding the queue forever.

Reconnect to the pump to resolve provisional data first. If a source change or unresolved old history requires a new period, the explicit **Start a new reporting period** action archives the old history and begins from now. It does not amend existing Glooko records. Removing the service stops/cancels its work and removes its credentials; account-scoped history remains for reconnection.

## Layout and build

| Path | Contents |
|---|---|
| `GlookoKit/` | LoopKit-free client, production IBF writer, durable history/repository and readback verifier |
| `GlookoServiceKit/` | Loop service, source/settings context and dose adapter |
| `GlookoServiceKitUI/` | Cancellable sign-in and live status/recovery screens |
| `GlookoServiceKitPlugin/` | Plugin principal class and discovery metadata |
| `Tests/GlookoKitTests/` | Production-file decoder regressions, history/recovery, account migration and accepted synthetic golden files |

The core builds/tests on macOS with `swift test`. The iOS plugin builds inside LoopWorkspace:

1. Add this repository to LoopWorkspace, for example as a submodule named `GlookoService`.
2. Add `GlookoService/GlookoService.xcodeproj` to the workspace.
3. Add `GlookoServiceKitPlugin` to the workspace scheme's build action.
4. Build/install Loop normally. Loop's `copy-plugins.sh` embeds the plugin and its frameworks.

After adding source files, run `xcodegen generate` and include the regenerated project with the change.

## Verification and limits

The repair was exercised with offline history replays, two four-day simulations with interrupted/automatic boluses, suspensions, replacements, resends, persistence and simulated failures, and an independent IBF decoder. All checked complete-day basal/bolus totals matched. Twelve package tests pass.

A revised synthetic file was accepted in the isolated test account and **all 18 eligible final clinical records passed the production readback verifier**. The supplied nondefault maximum doses, insulin duration, carb ratio and sensitivity were also read back from Glooko settings. This establishes the tested file contract; it does not prove every real pump history or clinic report.

Remaining format/product limits:

- Automatic boluses/temps appear as ordinary boluses/temps.
- Interrupted boluses retain delivered volume but not their original programmed amount in Glooko's decoded records.
- The previously observed detailed-row discrepancy on clock-change days remains; daily-summary parity was observed in the earlier fixtures. Travel/time-zone reconstruction is limited by source context.
- CGM is not uploaded; it requires its separate connection, such as Dexcom.
- Bolus amounts use the format's hundredth-unit precision; therapy profiles use the native profile precision.
- Two-factor sign-in and regions outside the EU are unsupported.
- Submitted clinical corrections remain reviewable conflicts until a supported amendment contract is established or the user explicitly archives the period.
