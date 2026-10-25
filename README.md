# GlookoService: Loop → Glooko pump history

A reporting-only Loop service plugin. It sends Loop's reconciled insulin delivery (scheduled basal, temporary basal, suspensions, boluses) to a Glooko account as an Insulet Omnipod (Eros) PDM download. Glooko then shows the basal and bolus records and generates its own daily totals and report statistics. It never doses, changes settings or acts on remote commands.

## How it works

- `uploadDoseData` maps each pump `DoseEntry` to a `SourceDose` (manually entered pen doses are skipped) and stores it in a durable virtual-PDM history (`PumpHistoryLog`, in Application Support) **before** acknowledging, so Loop's cursor never advances past unsaved doses.
- History is committed only once settled: older than one hour, not past the newest reported basal (Loop's overlay inserts scheduled basal only between later doses), and before any dose Loop still marks mutable. Committed records keep their PDM indices forever.
- At most every 15 minutes it posts the whole history (14-day window) as an IBF file to `POST https://eu.api.glooko.com/api/v3/device/file/upload?extractorName=InsuletOmnipod` with the patient session. Glooko de-duplicates repeated records; the running basal is flagged in progress and finalised on a later upload.
- Sign-in uses the Glooko e-mail and password (Keychain). The session is renewed automatically, and the account e-mail is re-verified before each re-sign-in.

## Layout

Same shape as LoopKit's own services (NightscoutService, TidepoolService):

| Path | Contents |
|---|---|
| `GlookoKit/` | LoopKit-free core: Glooko client, IBF encoder, durable history log. Also a Swift package (`swift test`) |
| `GlookoServiceKit/` | `GlookoService`: Loop `Service` and `RemoteDataService`, dose mapping, uploads |
| `GlookoServiceKitUI/` | Sign-in and status screens (`ServiceUI`) |
| `GlookoServiceKitPlugin/` | `.loopplugin` principal class and the Info.plist keys Loop discovers |
| `Tests/GlookoKitTests/` | Encoder golden files and history-log replays |

## Add to LoopWorkspace

1. Add this repository to your LoopWorkspace checkout, e.g. `git submodule add <url> GlookoService`.
2. In `LoopWorkspace.xcworkspace/contents.xcworkspacedata`, add a `FileRef` to `GlookoService/GlookoService.xcodeproj`.
3. In the `LoopWorkspace` scheme, add a build entry for the `GlookoServiceKitPlugin` target.
4. Build and install Loop as usual. Loop's `copy-plugins.sh` embeds the plugin and its two frameworks.

After adding source files, run `xcodegen generate` and commit the regenerated project.

## Use

Loop → Settings → Services → Add Service → **Glooko** → sign in. The status screen shows the last upload, how far history is committed, the virtual PDM serial and any doses that arrived too late to include.

## Verified (isolated test account, synthetic data)

- Detailed records and Glooko's own daily summaries match the source for every complete day, across incremental uploads, simulated failures, resent and replaced doses, interrupted and automatic boluses, suspensions and an uncovered pod gap. Summaries match to Glooko's 0.05 U rounding.
- Overall statistics (`basalUnitsPerDay`, `bolusUnitsPerDay`, `totalPumpInsulinPerDay`) are populated and correct.

## Known limitations

- Automatic boluses and automatic temp basals show as ordinary boluses and temp basals; the Eros format has no automation flag. Totals are unaffected.
- A bolus's programmed amount is not kept when it was interrupted; the delivered amount is correct.
- On the two clock-change days, the daily summary is correct but the detailed rows are off by about half a unit, because Glooko keys them by wall-clock time (as with a real PDM).
- Carbs and CGM are not sent. Glucose already reaches Glooko from Dexcom.
- A dose Loop reports more than an hour late cannot be added to committed history; it is counted on the status screen.
- The current day's summary appears once the day is complete and its last record final.
- EU region only.
