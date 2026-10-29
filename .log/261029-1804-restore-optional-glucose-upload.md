# 261029-1804 - Restore glucose uploads with a default-on control

Garry requested glucose reporting for direct Dexcom and Libre connections, an independent switch defaulting on, publication on main and installation on the Ultimate iPhone. The previous live build deliberately uploaded no glucose, so the control was genuinely absent. This change restores the sender and adds it to setup and a dedicated Glucose section in the saved service.

## Route decision and attribution

Opened the removed uploader in ab79f4e and its parent, the current async LoopKit RemoteDataService callback, StoredGlucoseSample, the host's glucose-query loop and GlucoseStore's zero-limit behaviour. The old code could not simply be restored: it filtered for Dexcom G7, used the old callback API and shared cache names with the retired-data cleanup.

Investigated native CGM ingestion first, using only the isolated test account. GET cgm/egvs and cgm_devices worked, but PUT cgm/egvs returned HTTP 400 with Not available for the tested envelopes. Complete inventories showed no new record and all 12 original CGM records unchanged. This failed approach does not establish that every partner or native writer is unavailable. Official Glooko LibreView-import and direct-integration documentation were consulted. After the attribution trade-off was explained, Garry again instructed implementation and deployment. Proceeded with the proven CSV route and explicit Abbott/CSV wording in setup, status, diagnostics and README.

The request identity remains Loop-GlookoService, without copied Glooko app user agents, deviceInformation, app version/build/git hash, device-derived serial, Origin or Referer. CSV rows identify their local source as Loop CGM / Loop, but Glooko still assigns its Abbott/LibreView CSV source. This cannot preserve native Dexcom attribution. No virtual pump or manufacturer identity is registered by this feature.

## Behaviour and ownership

The async callback persists eligible samples before acknowledging Loop. It accepts real CGM samples independent of sensor brand, including mmol/L conversion, and excludes manual, display-only, qualified, mock/simulator and Glooko-origin readings. It retains original instants and values locally; CSV uses minute-resolution local timestamps and two decimal places in mg/dL. Direct readings take priority over a pending manufacturer-app copy. Conflicting corrections and repeated clock minutes cannot silently overwrite immutable CSV data.

An account-scoped protected glucose-v2.json and initialisation marker are distinct from the retired glucose.json cache. Decode failures or missing acknowledged history block acknowledgement instead of starting an empty queue. Confirmed retention is bounded to 14 days while unconfirmed work is protected. Glucose format version 2 prevents stale retired-uploader raw-state flags being mistaken for a new outbox.

A glucose source query must drain before sending. Batches of up to 500 check existing stored records and graph points before submitting missing readings. Only exact, non-duplicate raw-record and graph matches are confirmed. A partial or failed verification remains pending. The lifecycle owns cancellation, authentication recovery and retry tasks; retry starts at 30 seconds and increases to 15 minutes. Insulin and carb senders remain independent.

Upload glucose defaults on for setup and for versions with no saved option. Off persists across restoration, cancels glucose requests/retries and sets the public query limit to zero. An in-flight source page is retained while off. Re-enabling resumes queued work; subsequent source queries supply further history. Loop's zero-limit query preserves its cursor. No private anchor keys are rewritten, and a complete historical backfill is not promised for older already-advanced cursors. A request already accepted by Glooko cannot be retracted merely by disabling uploads.

Diagnostics now expose glucose callback/query state, pending and confirmation information, request activity, and a read-only comparison of acknowledged readings against both records and graphs. The README explains setup, switching off, timing, conflicts, attribution, limits and removal, with a new actual simulator photograph and capture provenance.

## Verification

Drove the production core against the isolated account before the official suites. Two synthetic readings dated 16 September 2026, 12:00:31 and 12:01:41 UTC, at 100.25 and 101.50 mg/dL were accepted through CSV. Both exact stored CGM values and graphs matched. Replaying created no duplicates, and the original 12 records remained unchanged. Those two synthetic points remain only in the isolated account because individual CGM deletion through this route has not been established. No synthetic point was sent to the clinical account.

Built the complete LoopWorkspace simulator app and installed it on the existing loop simulator. Observed the default-on switch in the Glucose section, switched it off, terminated and relaunched Loop, observed the saved off value and restored on. CGM Simulator samples remained excluded. The native PNG is unmodified and contains no credentials or account address. The initial navigation attempts encountered the simulator's alarm prompt; dismissing it allowed the intended navigation.

After end-to-end operation, swift test passed all 42 core tests. The iOS service suite passed all 14 tests, including Dexcom/Libre units, exclusions, source draining, default-on and off persistence, pending work while disabled, raw acceptance without graph confirmation, replay, cancellation, manual retry, automatic retry without another callback and damaged acknowledged storage. Existing insulin, carb and authentication tests passed. One first-run cancellation test waited for any cancellation and released its held request too early; the fixture now waits for that held request's stopLoading event. The full suite then passed, with no runtime change needed for that test correction.

Reviewed the source, lifecycle/account guards, relevant SDK implementations and changed tests using code-reviewer-cx and test-audit. No outstanding high-confidence issue was found. Whitespace and local README/image links passed. The project file includes the restored source; its folder-based XcodeGen source already includes it. XcodeGen is unavailable locally, so the exact original project references were reinstated and verified by successful Xcode builds rather than installing tooling outside the workspace.

Publish this coherent feature on main using the personal Git identity, then build the phone from that clean commit. Phone deployment and actual clinical readback are recorded separately after installation. Private commands, response inventories, simulator captures, test results and the pre-install phone snapshot are ignored under Repos/glooko-glucose-restore in the parent workspace.
