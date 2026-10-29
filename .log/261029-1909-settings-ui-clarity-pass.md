# 261029-1909 - Make the Glooko settings screens consistent and plain-spoken

Garry asked for a frontend-design pass over the Glooko section so it is consistent, clear and understandable for anyone using it. He also asked for a test and a deployment to the iPhone. The change is UI-only: `GlookoServiceKitUI/GlookoService+UI.swift` and `GlookoServiceKitUI/DiagnosticsView.swift`. No service behaviour, stored state or public API changed.

## Direction

The section lives inside Loop's settings, so it stays a native iOS grouped form, following Loop's other service screens. A distinct visual identity would fight the host app. The one deliberate addition is a status header that answers "is it working?" at a glance. The rest of the effort went into structure and wording.

## Problems found and what changed

Status screen:
- Toggles were scattered. Insulin and mobile-data switches sat in "Upload routes", glucose in its own section and carbs had none. Insulin, glucose and carbs now follow one pattern: switch first, then *Last confirmed*, *… sent through* and *Waiting to send*. Carbs state that they are always sent.
- "Sign in again" and "Change sign-in settings" opened the same screen. They are now one button, *Change account or sign-in options*. An expired session also shows a *Sign in* button in the header.
- The header showed only the pump label. It now shows the health of the service: *Up to date*, *N waiting to send*, *Some data can't be sent* or *Sign in needed*, followed by the account email (truncated in the middle). The email row under Account was removed as a duplicate.
- The sending controls (Send now, mobile data, alert delay, test alert) are now grouped under *Sending*. Jargon such as "eligible data waits" is now *Alert after*.
- *Shown in Glooko as "MockPumpManager via Loop"* was inaccurate, because Glooko names entries by insulin, not pump. The row is now *Pump*.
- On the real phone, "1 of 1 insulin entries confirmed" sat under "Entries in Glooko 22" and read as a contradiction. Those service details describe the latest batch, as shown by the strings in `InsulinOutbox.swift:251`, `CarbOutbox.swift:196` and `GlookoService.swift:899`. They now read *Last send: …* in footnote size.
- The insulin rows and timing footer are hidden while insulin is off. The footer then reads as a one-line invitation to turn it on.
- Dates now read *Today at 18:21* or *Yesterday at …*. Earlier dates this year use *29 October at …*, and older ones use the full date in British format. Previously long dates wrapped onto two lines. Missing dates now read *Not yet* instead of *Never*.
- Footers were shortened. The repeated Abbott/CSV explanation and the OAuth developer note were removed.
- The delete alert buttons now share one verb: *Delete and keep local history* and *Delete and erase local data*.

Sign-in screen: the field label is *Email*, not "E-mail". The password option is *Save password on this iPhone*, with a plain explanation of the Keychain. The section is *What to send*, with Insulin and Glucose toggles and a note that carbs are always sent. Mobile data has its own section. The intro footer no longer claims insulin is sent while its toggle defaults to off.

Diagnostics: the 20-row "Insulin and queues" list is split into Insulin, Glucose, and Carbs and settings sections. Callback jargon is now *Last received from Loop* and *Loop history loaded*. "Missing / different" is now two rows.

Consistency: every error, warning and replay notice uses one `GlookoWarning` view, a red triangle with primary text. Red is kept for warnings only, in line with the Loop colour convention. Orange was dropped for warnings because orange is Loop's insulin colour.

## Testing

Tested on the `loop` simulator (Device Hub, iOS 27.0) with the isolated test account. I captured the baseline, rebuilt after each round and walked every screen: status, sign-in, diagnostics, live check and the delete alert (cancelled). I turned insulin on and off: the simulator-pump guard warning appeared and then cleared, and insulin ended off, as it started. The live check found that the test account's Glooko session had expired. This was pre-existing and not caused by the change. It confirmed the *Sign in needed* header and the inline reason. The test account was not signed in again because its password isn't available to this session, so it remains signed out.

Driver quirks, not app faults: the first phone-control tap after a fresh launch often missed (retried), and switches needed a knob tap (`tapXY`).

The official iOS service suite (GlookoServiceTests) passed: 14 tests, 0 failures. Core `swift test` was not rerun because GlookoKit is unchanged.

## Deployment

Built LoopWorkspace Debug for generic iOS with `-allowProvisioningUpdates`. `codesign --verify --deep --strict` passed. Installed in place on the Ultimate iPhone (`00008160-001C6C3E08834036`) twice, the second time after the *Last send* fix. The embedded build is `c7964ee.dirty` because the change is uncommitted, as Garry did not ask for a commit. The phone was only viewed: header *Up to date*, Pump *Omnipod 5*, 22 insulin entries, glucose current to 19:06, password saved, dark mode correct. No toggle, dose, carb or therapy control was touched. The phone was returned to Now and showed *Closed loop*.

Evidence (screenshots, accessibility trees, build, test and install logs) is in the parent workspace's ignored `Repos/glooko-ui-review/`.

## Open

- Commit and push of the two UI files and this entry are pending Garry's say-so.
- The simulator test account needs signing in again before the next live simulator check.
- README screenshots predate this layout.
