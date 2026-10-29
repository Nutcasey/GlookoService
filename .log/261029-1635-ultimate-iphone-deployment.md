# 261029-1635 - Deploy the honest client and status fix to the Ultimate iPhone

Garry explicitly requested deployment to his phone and an update to the service repository. The source changes were already published on main as 03af1ca, including the honest Loop-GlookoService identity and the inactive-insulin warning repair. Built and installed that clean revision, then verified the existing real account from the phone. This record supersedes earlier deployment-status notes that said the new transport was simulator-only; those historical records are retained.

## Build and installation

Built the LoopWorkspace scheme in Debug for generic iOS with the existing signing configuration, allowProvisioningUpdates and 16 jobs. The workspace build succeeded. Verified the complete app bundle with codesign --verify --deep --strict. It retained bundle identifier com.D97WFNARR9.loopkit.Loop, Loop version 3.15.2 (58), and the existing app-group identifier. The embedded service metadata reported clean 03af1ca; its framework contained the honest client identity and no copied GlookoiOS user-agent string.

Installed in place on the explicitly selected Ultimate iPhone, iOS 27.2, and launched it successfully. The other connected iPhone was not targeted. Loop host source remained 415926dd with the documented restored-device snapshot and restored-service query edits. No host source, signing configuration, therapy selection or pump pairing was changed during deployment.

## Before and after verification

Before installation, copied the service's existing account history and outboxes into private ignored evidence storage. They identified Omnipod 5, Novolog, 20 confirmed insulin entries and no waiting entries. The existing records had the expected named insulin labels. Captured the app-group preferences separately as deployment evidence; no credentials were printed or published.

After installation, the phone displayed Omnipod 5 via Loop, the existing account and service build 03af1ca. Comparing fresh on-phone service storage with the pre-install capture showed:

- Exact equality of reported therapy schedules and limits, source identity, insulin selection and reporting start.
- All 20 previously tracked insulin entries preserved exactly, including their identities, quantities, timestamps and confirmation state.
- No pending insulin entries after restoration.

Used only the phone's read-only Check Glooko now control. At **16:32:55 GMT on 29 October 2026**, it reported **20 matched, 0 missing and 0 different**, with both dose and settings queries finished and no pending insulin or carb confirmation. A fresh copy of diagnostics independently confirmed insulinVerified true and the same counts. This verifies existing confirmed records with the deployed client identity; it is not a forced new insulin submission.

Returned the phone to Loop's Now screen, which displayed Closed loop. No dose, carb, upload-option, password-recovery or therapy-setting control was operated. No synthetic record was sent to the real account. The earlier simulator and controlled-failure results remain in the 15:38 validation record; no official suite was rerun for an unchanged runtime build and documentation-only publication.

## Repository and evidence

Update the README's physical-device verification to reflect this completed installation. Publish this record and README on main using Garry's personal Git identity. The installed runtime is clean 03af1ca; the subsequent commit records deployment documentation rather than another runtime change.

The parent workspace retains private evidence under ignored Repos/glooko-phone-deployment-261029: build/install/launch logs, signed-build hashes, before/after/final service captures, comparison results and phone screenshots/accessibility trees. Source review, README link validation and whitespace checks passed. The parent records the new service pointer without publishing unrelated work.
