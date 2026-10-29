# 261029-1538 - Exercise the honest client in the simulator and repair a stale warning

Garry requested thorough simulator testing of the client-identity change. Built and operated the actual Loop app before running the official iOS integration suite. Used only the existing Device Hub `loop` simulator, an iPhone 18 Pro on iOS 27.0, with Xcode 27.1. The initial installed plugin was clean `6c34380`; verified its embedded build metadata and the honest user-agent string in its installed framework. Loop host source was `415926dd` with the documented restored-device snapshot and restored-service query changes.

## Actual app and live-server checks

All live checks used the existing isolated test account, verified against Glooko's users endpoint. Captured complete insulin and food inventories before UI writes. Independent readback requests used the honest identity and performed no clinical record mutations. Passwords/session values remained in memory; secret-bearing typing activity bundles were removed rather than retained as evidence.

| Exercise | Observed result |
|---|---|
| Existing service after installation | Session restored; correct build and MockPumpManager source displayed |
| Cancel sign-in settings | Returned to the existing connected service |
| Fresh sign-in from the app | Succeeded with the honest client; password recovery remained off |
| Send test alert | Expected Glooko test alert displayed and acknowledged |
| Enable insulin reporting with the pump simulator | Expected real-pump-unavailable alert and pause; zero simulator insulin reported |
| Check Glooko now | Dated authenticated readback; both source queries finished; no pending queues |
| Create a carb entry | Saved 27 g through Loop using Save without Bolusing; one Glooko food confirmed |
| Repeated Upload now | Still one food identity; no duplicate or unrelated changes |
| Edit through Logbook | 27 g → 34 g on the same Glooko food GUID |
| Terminate and relaunch Loop | Saved session, both enabled upload options, original 11:27 reporting start, source callbacks and confirmed carb state recovered |
| Readback after restart | Same 34 g GUID, both source queries finished, no pending carb confirmation |
| Disable insulin/cellular again | Both original off settings restored |
| Delete the carb through Logbook | Same GUID confirmed soft-deleted, retaining 34 g; local outbox also recorded the confirmed deletion |
| Full inventory comparison | All 227 pre-existing insulin records and all 14 pre-existing foods unchanged; exactly one new food identity, now deleted |

The app's own request traces recorded HTTP 204 for each food create, edit and delete. Independent server reads established the values and identities, rather than inferring success from the app's button or HTTP acceptance. No delivery action was invoked; recommendations on the carb screen were changed to zero before selecting Save without Bolusing. Simulator insulin remained excluded throughout.

Automation initially needed the actual switch knob rather than the centre of its accessible row, and the carb input did not expose the expected identifier. A focused bolus field also needed Done before its save action became available. These were corrected in the temporary driver; the early read made before saving correctly found no new food. Final successful workflows and inventory comparisons establish the resulting state. No production test seam or additional unit test was added for these control adjustments.

## iOS integration suite

After the app/server workflow succeeded, rebuilt the actual GlookoServiceTests host and ran its complete suite on the same simulator, with parallel testing disabled: **11 tests passed, zero failures**, completed at 15:31:56 GMT.

The suite exercised original-dose versus historical insulin selection, disabled legacy glucose uploads, restored query draining without premature alerts, shared authentication recovery and stopping after credential rejection, edits arriving during submission, manual carb retry without an eligible pump, timed retry without another source callback, damaged/missing acknowledged storage, cancellation during multi-request service removal, and source deletion during authentication. It uses real LoopKit values, filesystem, Keychain and service lifecycle with intercepted HTTP; these controlled failures were not induced against the live account. The same core code's earlier 40-test run also passed; it was not rerun without a new core change.

## Issue found and repaired

The final app check exposed a stale display: after disabling insulin reporting, its previous real-pump-unavailable error still appeared in red in the insulin section. Carb create/edit/delete and acknowledgements were already working correctly. Show the insulin status error only while that stream is enabled. Preserve the stored error and diagnostics, the separate account-authentication section, carb errors and health-alert handling.

Rebuilt and reinstalled the actual app after this UI-only change. Verified its installed UI framework matches the rebuilt binary. Before the repair the disabled status contained the glooko-error row; afterwards it did not. Enabling insulin still produced the expected real-pump warning, and the status warning was visible again when scrolled into view. Restored the original disabled switches at the end. The official service suite predates this final display-only change; the changed UI was checked directly in the app instead of adding a source-mirroring test or repeating unaffected service tests.

## Evidence, review and limits

Private evidence is in the parent workspace's ignored `Repos/glooko-simulator-validation/`: workspace build logs, installed-build manifest, numbered UI screenshots/accessibility trees, baseline and phase-by-phase server inventories, integration build/test logs and xcresult. README verification now links this record and distinguishes the earlier physical-device check from current simulator testing. Whitespace/link checks and code-reviewer-cx review of the final three-line UI change passed.

No simulator was created, no physical phone was used and no real therapy setting was changed. Positive real-pump insulin transfer and Glooko's exact native row layout cannot be established with the simulator guard enabled. Earlier production-writer live checks and this run's intercepted iOS adapter tests provide the positive insulin-path evidence; this run does not claim a new physical-device validation.
