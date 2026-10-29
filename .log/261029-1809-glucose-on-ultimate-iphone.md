# 261029-1809 - Deploy glucose uploads and verify the Ultimate iPhone

Garry explicitly requested implementation and deployment of the default-on glucose uploader. Published the completed feature, tests, README and actual simulator capture on main as f71a78f. Built that clean revision and installed it in place on the Ultimate iPhone on 29 October 2026. This record supersedes earlier notes that glucose was not implemented or installed.

## Build and installation

The LoopWorkspace Debug build for generic iOS succeeded with the existing signing configuration and allowProvisioningUpdates. The complete Loop.app bundle passed codesign --verify --deep --strict. Its bundle identifier remained com.D97WFNARR9.loopkit.Loop, version 3.15.2 (58). Embedded GlookoBuild.plist reported f71a78f, dirty false, built at 18:05:14 GMT. The framework contained the CSV route and honest Loop-GlookoService identity, without the copied GlookoiOS user-agent string.

Installed on the explicitly selected Ultimate iPhone at approximately 18:05 GMT, then launched it. The other connected iPhone was not targeted. Kept the existing app container, real Glooko session and password-recovery choice. No uninstall, sign-in, pump pairing, dose, carb entry, closed-loop change or therapy-setting operation was performed. The Loop host remains 415926dd with the documented local restored-device snapshot and restored-service query changes; those edits were not changed or committed to the host branch during this deployment.

## Actual reporting and readback

Before installation, captured the account's service history, outboxes and app-group preferences into ignored private evidence. After launch, the restored service used its existing reporting start and automatically staged 90 eligible real sensor readings. All 90 were confirmed against Glooko stored CGM records and graphs. A subsequent natural sensor update brought this to 91, showing continued uploads beyond the initial backlog. No synthetic glucose was introduced on the clinical phone or account.

Opened Settings → Glooko and observed Upload glucose, enabled, in the dedicated Glucose section. Used Diagnostics and live check → Check Glooko now, which is read-only. At **18:07:39 GMT**, fresh on-phone diagnostics reported:

- Glucose expected 91, stored matches 91, graph matches 91 and duplicate minutes 0.
- Insulin matched 21, missing 0 and different 0; insulinVerified true.
- Glucose source query finished and no glucose, insulin or carb records awaiting confirmation.

Fresh service-storage captures independently confirmed all 91 glucose records acknowledged and zero pending. Compared with the pre-install capture, all 21 previous insulin entries were exactly unchanged, including identifiers, values, dates and confirmation state. The reporting start, latest reported therapy settings, real pump identity, insulin selection and time zone were unchanged.

Returned to the Glucose section to confirm the visible enabled switch and zero waiting count. The phone's switch was not toggled during verification; off/restart/on and cancellation were already tested on the simulator and in the service suite. Returned the phone to Now at approximately 18:09 GMT and observed Closed loop. No further build, install or device-control process remains running for this task.

## Publication and evidence

Update the README to report this physical deployment and readback. Publish this documentation record on main using the personal Git identity. The installed runtime remains clean f71a78f; the subsequent commit records evidence without changing executable code. The 42 core and 14 iOS service tests passed before that runtime was published. No suite was repeated for this documentation-only addition.

Private evidence is in the parent workspace's ignored Repos/glooko-glucose-restore: signed-build manifest, build/install/launch logs, before/after/verified service captures, aggregate comparison JSON, on-phone accessibility trees and unmodified screenshots. These contain clinical timings and remain out of the public repository. Public documentation uses the isolated-account simulator image only. README local-link and whitespace checks passed. The parent records the service pointer without publishing unrelated work.
