# 261029-1132 - Consolidate the next-dev integration on main and rebuild the README

Garry requested one canonical branch for this new service, with all current functionality on `main`, then a comprehensive README illustrated with genuine simulator captures. This supersedes the earlier decision to publish the async port and insulin labels only on `next-dev`.

## Branch and documentation decisions

Fast-forwarded local `main` from `ef82233` through the next-dev port `2f356e2` and selected-insulin labels `f0a9ce7`. Pushed that complete runtime history to `origin/main` before finishing the documentation. No force push or history rewrite was required. `main` now targets Loop/LoopKit next-dev; the older completion-handler variant is not maintained separately. The existing next-dev branch is retained, but new service changes belong on main.

Replaced the README from the ground up. It now covers the data boundary, workspace installation, account setup, persistent queues, stable identifiers, insulin-name attribution, timing, readback, alerts, recovery, privacy, removal, legacy migration and known limitations. It distinguishes a text insulin name from a catalogue medication, basal delivered units from a pump timeline, and a zero-entry connection check from proof of clinical transfer. The current basal-ready value is a delivery/settling horizon, not evidence of an uploaded record.

Rewrote the Loop integration guide and supplied `next-dev-host-integration.patch`. The patch requests existing source data when restoring a service and records a settings snapshot after restoring device managers. It was generated from the actual two-file difference against Loop `415926dd`. The older dev patch remains explicitly historical. The host changes are distributed as an integration patch; this documentation commit does not publish a separate Loop repository change.

## Captures and evidence

Built the actual LoopWorkspace scheme for the existing Device Hub `loop` simulator and installed the matching bundle. Took four unedited native PNG captures: empty setup, setup options, signed-in status and diagnostics. Visually inspected every image. The signed-in captures use the isolated account and omit its account section. Credentials stayed in memory; secret-bearing XCTest activity output was not retained as documentation evidence.

The final read-only check completed at 11:32:09 GMT on 29 October 2026. Both dose and settings queries showed finished, and queues were empty. There were zero confirmed insulin entries. These screenshots therefore demonstrate the UI and authenticated readback, not a clinical insulin upload or Glooko's own row layout. No real phone or real therapy configuration was changed for documentation.

A global simulator SDK override initially misdirected watch targets; the workspace build succeeded with destination-based SDK selection. An empty development-team override initially produced a different bundle identifier, leaving the previously installed app visible. Rebuilt with the correct bundle identifier, verified the installed framework contained the new insulin-name footer, and removed the accidental extra simulator app. These were capture/build corrections, not new production defects.

## Verification and publication

- Simulator workspace build succeeded with ad hoc signing; source is the existing tested service plus the documented host patch.
- Applied the patch to clean copies of Loop `415926dd` and byte-compared both resulting files with the actual simulator build sources: exact matches.
- Checked README claims against `InsulinOutbox`, service lifecycle and options, `ReportingContext`, diagnostics, Keychain storage, and the actual setup/status UI. Referenced Loop's official build guide and Glooko's insulin-display documentation.
- Checked relative documentation links, image dimensions and hashes, and whitespace. No extra unit/integration suite was run for this documentation-only change. Runtime results remain the previously recorded 39 core and 11 iOS integration tests.
- Reviewed the documentation and integration patch for high-confidence defects using the code-reviewer-cx criteria. No outstanding issue was identified.

Publish this documentation, current integration patch, screenshot provenance and work record to `main`, using Garry's personal Git identity. The parent workspace tracks the new service commit separately and retains its unrelated local work.
