# 261029-1041 - Label delivered insulin with the selected drug and Loop origin

The generic delivered-insulin uploader omitted a display name, leaving empty brackets in Glooko's Daily log. Retain the insulin recorded by Loop and upload a name such as `Fiasp via Loop`, without changing the declared basal/bolus kind or dose quantity.

## Contract and implementation

- Preserve the optional drug name on source doses and settings contexts. Prefer the original dose's type; use a settings fallback only for its delivery time and only when that interval does not span a drug change. Do not infer old insulin from the current selection or action duration.
- Keep `medicationGuid` null. Isolated API experiments demonstrated that linking a rapid-acting catalogue medication can turn requested basal into bolus and replace a custom name. A separate text name preserves the tested delivery classification; the existing Loop-namespaced external ID retains machine-readable origin.
- Give mixed-drug basal hours a combined label while keeping the same hourly GUID and measured volume. Include unknown contributions explicitly. Entirely unknown entries are named `Insulin via Loop`.
- Optional fields keep old persisted data readable. Refresh queues nameless saved entries for metadata updates on their existing GUIDs, without guessing a missing historical drug. Confirmation now checks the uploaded name as well as the established clinical fields.
- Update setup/status descriptions. Clear the resolved source-query wait message after both streams drain, while retaining unrelated errors.

## Evidence and verification

Operated the actual production core with a temporary standalone Swift driver before the official suites. The offline scenarios covered mixed insulin, unknown fallback, persistence and same-GUID label migration. Against a verified isolated account, seeded three nameless synthetic entries, added labels through production `submitInsulin`, replayed without duplicates, corrected a synthetic name on the same GUID without changing its amount, and ran production read-only verification. All passed. Cleanup confirmed all three deletions, exact preservation of pre-existing rows and no unrelated new GUIDs. Credentials stayed in process memory.

- `swift test --package-path GlookoService`: **39 passed**. The new persistence/upgrade regression failed against the pre-change core for the intended missing-name and missing-migration behaviour.
- `GlookoServiceTests` on the existing Device Hub `loop` simulator: **11 passed** in the final complete run. The adapter scenario covers original-dose precedence, historical settings fallbacks, a same-action-duration drug change and an unknown interval spanning the change.
- Extended the existing restoration/drain scenario after the phone check exposed a stale source-wait message. It failed on the pre-fix service for that exact message, then passed after the repair. A clock-dependent basal fixture assumption caught during a full rerun was corrected by aligning the scenario to a whole hour.
- Signed workspace builds succeeded; the plugin was installed on the requested iPhone. The user established the real account connection. Authenticated live readback succeeded, but no eligible clinical entry existed in the new reporting period at the final check, so exact native Daily log wording still awaits the first real upload. No synthetic insulin was written to the real account.
- Code-reviewer-cx review and `git diff --check` found no outstanding high-confidence issue. Test-audit checks kept coverage at the core persistence and iOS adapter boundaries without adding a test-only production hook.

Private captures and temporary drivers remain outside this repository's tracked files. The parent workspace retains the detailed deployment record and evidence paths. The installed code was tested before publication; changing the Git commit does not require another clinical upload or device install.

## Related host work and publication scope

The real connection exposed a separate Loop next-dev startup issue: an earlier device-less settings snapshot could remain newest after the pump managers restored. A small host change publishes a restored-device snapshot; phone readback then identified the real pump and selected insulin with unchanged reported therapy schedules and limits. That edit belongs to the separate Loop repository and is **not included here**. This service continues to require a valid source rather than hiding genuine pump removal.

Garry explicitly requested updating GlookoService after deployment. Publish this change to `next-dev`, using the personal Git identity, because `main` retains the older LoopKit completion-handler API. No port to `main`, parent-repository commit or Loop host commit is part of this publication.
