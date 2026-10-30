# 261030-0811 - Repair the nine current-code review findings

Garry requested comprehensive fixes for all nine findings from the 29 October review, followed by an update and deployment to the Ultimate iPhone. This entry records the implementation and validation. Physical deployment is recorded separately in the parent workspace. The service started clean on `main` at `6c3da1d`. No commit or push was requested, so the changes remain uncommitted.

## Decisions and implementation

1. **Basal retention.** Added a persisted recomputation boundary independent of reportingStart. Pruning moves only to complete UTC-day boundaries and keeps the source intervals needed by each retained day's rounding accumulator. Pending entries and mutable deliveries protect their days. Recomputing cannot recreate a discarded hour from retained fragments of a long interval. For an older cache that may already have lost part of its first retained day, its saved entries stay as recorded and recomputation starts at the next complete day. A never-submitted legacy backlog still computes in full. Earlier incorrect remote data cannot be reconstructed if its original source intervals have already been discarded; this limitation is documented rather than hidden by an invented correction.

2. **Dose provenance.** The public DoseEntry query loses HealthKit provenance before the plugin sees it. Inferring source from current pump settings cannot exclude external injections or copies. Added an opt-in `RemoteDataService.doseDataIncludesOtherApps` requirement in the matching LoopKit checkout, defaulting to true for existing services. Glooko returns false. The matching host forwards that option to `InsulinDeliveryStore.executeDoseQuery(includeOtherApps:)`; the store filters using its original provenanceIdentifier and hasLoopKitOrigin fields. It retains the existing cursor semantics. No insulin-ingestion or dosing path was changed, and no metadata was invented or encoded in a dose description. The existing manual/simulator checks remain. The SDK/host changes and installation requirements are included as independently application-checked patches under Documentation/Loop.

3. **Temporary account-check failures.** HTTP 429/5xx and malformed identity responses now remain retryable errors. Only a successful identity response showing another or deleted account raises accountMismatch. The old persisted false-mismatch message is rechecked once under the corrected handling; every submission still requires account verification, so a real mismatch continues to block writes.

4. **In-flight glucose.** Added durable submission intent, saved in the same queue transaction that captures a batch, before its first request. Higher-priority direct readings replace manufacturer-app copies only when those copies are known never to have been submitted. Potentially submitted values remain immutable through cancellation and restart. Legacy entries without the new marker are treated conservatively as potentially submitted. A later overlapping copy does not strand the accepted value or block the next source page.

5. **Historical clocks.** New insulin and carb entries retain their reporting UTC offsets. Refreshes, edits with the same original time, retries, verification and replacement insulin identities reuse those offsets. The settings context also retains the controller's time zone for carbs. A one-time read-only migration recovers older entries' original offsets from their own server GUIDs and persists that metadata before any resend. A complete scan is required; failures do not cause a timestamp rewrite. Missing GUIDs use their captured historical context for their first submission. Confirmed values and identifiers remain unchanged by metadata migration.

6. **Carb readback.** Unresolved carb GUIDs fall back from the recent-update cursor to a complete scan. Accepted no-op retries, including repeated deletions, can therefore confirm even if the server retains an old update time.

7. **Reauthentication.** Successful sign-in schedules a forced drain after the new lifecycle and client are installed, outside the state queue. Existing pending work resumes without another source callback. Cancellation and generation guards still prevent an old request owning new state.

8. **Inactive insulin warnings.** Insulin storage errors contribute to upload-paused notices only when insulin reporting is enabled. The error and queue are retained, so enabling the stream still exposes the real problem.

9. **Diagnostic privacy.** Transport errors record domain/code instead of NSError's URL-bearing userInfo. General redaction removes URL credentials, query strings and fragments before truncation. Restored diagnostic events and inspection errors are sanitised too, as are retained service error/details. Sync scans use the safe transport description so errors returned as scan outcomes cannot bypass the fix. Sparse HTTP traces remain unchanged.

## Operating evidence before the official suites

Compiled the actual production core with an isolated URLProtocol driver in the parent's ignored `Repos/glooko-fixes-261030/`. Replayed the original review scenarios. The confirmed 1 U hour produced no partial resend after pruning; HTTP 503 remained retryable; a food outside the recent cursor confirmed through a complete read; a captured 120 mg/dL manufacturer sample remained confirmable after a 121 mg/dL direct copy arrived; retained insulin timestamps stayed unchanged under a different supplied zone; and patient query parameters were absent from the resulting diagnostic event. No driver request contacted Glooko.

Built the complete matching workspace for the existing `loop` simulator, installed it and operated its existing isolated-account Glooko screens. The live check completed with source history loaded and no queued insulin. Zero matched insulin is only a connection check on this simulator; it is not clinical reporting evidence. Simulator pump and CGM sources remain excluded. The screenshot/tree captures are private evidence, not replacement public documentation images.

The four portable new regression cases were run against the untouched original service source in an ignored archived checkout. Retention, account failure classification, accepted-carb readback and diagnostic privacy all failed for the intended reasons. An additional regression exposed loss of the original offset when a deleted insulin GUID moves to a new revision. Fixed that by carrying the preceding tracked entry's clock through identity replacement; the regression then passed.

## Final official checks

- Core: `swift test --package-path GlookoService --scratch-path Repos/glooko-fixes-261030/swift-build` — **46 passed, zero failures**, including the final replacement-clock repair.
- Service: matching-framework `GlookoServiceTests` build, followed by test-without-building on `loop` — **19 passed, zero failures**. The final rerun after the clock repair passed all 19. Added lifecycle cases cover reauthentication, a transient account error and the older false latch, a held glucose POST plus restart/replay, disabled-insulin storage alerts with an enabled-stream positive control, and old-schema clock migration through travel, restart, readback and real edits.
- SDK: `LoopKitHostedTests/InsulinDeliveryStoreQueryTests` — **eight passed, zero failures**. The new case uses the real persistent store and public query, with external/live/deleted/untrusted records, an empty drain and subsequent own-app data. Existing inclusive-query cases remain unchanged.
- Both current integration patches pass `git apply --check` against pristine copies of their documented Loop `415926dd` and LoopKit `b6db6e18` base files.
- Final code-reviewer-cx pass inspected the changed owners, persisted-state migrations, public SDK defaults and host forwarding. No remaining high-confidence finding in the authorised changes. Test-audit retained focused owner-boundary regressions without production hooks for testing.
- Whitespace checks passed in the service, LoopKit and host checkouts.
- Generic-iOS LoopWorkspace build succeeded; `codesign --verify --deep --strict` passed. Embedded GlookoBuild.plist reports `6c3da1d.dirty`, built at 07:59:19 UTC on 30 October 2026. The parent evidence folder retains the exact source hashes and app-binary hash in phone-build-manifest.json. Documentation/log edits after that build do not change runtime code.

## Build and harness corrections

The SDK test fixture initially left its inherited Completion expectation unwaited; its assertions themselves passed. Corrected the expectation cleanup. Subsequent workspace builds using the common scheme name Shared selected different projects and replayed the older test bundle. Opened the build graph and checked the old binary timestamp before attributing the repeated failure. Used a temporary uniquely named workspace scheme derived from LoopKit's actual Shared scheme; its compiled test bundle passed all eight cases. The temporary scheme was then removed, with a copy kept only in ignored evidence. A project-only attempt also lacked the workspace's LoopAlgorithm package product. None of these attempts changed clinical or device state.

Navigation retries in the simulator were needed to scroll to Services and the Help section; no destructive command was submitted. Initial phone preference captures covered app/group UserDefaults, with the actual Services.plist and small legacy cache captured separately before installation. The phone already showed a stale CGM reading and a not-running notice before deployment; that is recorded as a baseline, not attributed to this reporting change.

## Scope and evidence

Runtime changes are confined to GlookoService and the narrow matching LoopKit/host query integration. Existing local host startup edits and workspace wiring were preserved. The service stays on main, LoopKit stays on its existing next-dev checkout, and the host branch was not switched. No real pump was paired, no therapy option was operated, and no synthetic clinical record was submitted to the real account. Physical deployment and post-install readback are the next separately recorded slice.

Private evidence is in the parent's ignored `Repos/glooko-fixes-261030/`: operating driver and outputs, baseline failures, core/service/SDK results and xcresults, patch application checks, simulator captures, phone pre-install copies and the signed-build manifest. Public docs explain the changed behaviour and the additional host/SDK requirements without exposing patient data or credentials.
