# 261031-1625 - Remove the Loop icon copied from the redesign PR

Garry noticed that GlookoService had picked up icons from the Loop UI redesign PR (#2621) and asked for them to come out of the service entirely.

## What it was

The Glooko status header showed a 44 pt Loop app icon from `GlookoServiceKitUI/Assets.xcassets/Loop.imageset/Loop.png`, which was added in `01c7a29` on 27 October. Its SHA-1, `e9004dff…`, is byte-identical to `Loop/DefaultAssets.xcassets/AppIconPreviewDay.imageset/AppIconPreviewDay.png` in the Loop checkout. That file was added by redesign commit `d1101940` ("Add Day and Night app icons and an appearance setting") and isn't on upstream `next-dev`. The accompanying `LoopArtwork-LICENSE.txt` said the icon was "copied without modification from LoopKit/Loop … 79bd68b0". `79bd68b0` is also a redesign commit ("Localise the redesigned interface…"), so the notice was wrong as well.

I searched the service for any other images or redesign references. The other image in the bundle is `Glooko.imageset`, the service's own icon. The other icons in the UI are system SF Symbols such as `checkmark.circle.fill`, `exclamationmark.triangle.fill`, `clock.fill`, `stethoscope` and `square.and.arrow.up`, which are not redesign assets. No other files came from the redesign.

## Changes

- `GlookoService+UI.swift`: the header is now just the status line and account email. The `HStack` and the `Image("Loop")` are gone.
- Deleted `Loop.imageset` and `LoopArtwork-LICENSE.txt`, and removed the licence file's four `project.pbxproj` entries. `plutil -lint` passes.
- `README.md`: the licence paragraph no longer mentions Loop artwork or the notice file.
- Screenshots: recaptured `status.png`, `status-dark.png`, `insulin-on.png` and `alert.png`, the four images that showed the header, and updated their hashes. The provenance file gained a recapture section.

Alternative considered: putting the Glooko service icon in the header instead. I didn't, because Garry said the icon shouldn't be there at all, and the header reads clearly without it.

## Host and capture

The earlier screenshots record their host as Loop `415926dd`, which is a redesign commit too. A strip of the redesign's coloured Now-screen buttons shows behind the sheet in all 13 images. For the recapture I built a plain host instead. It uses a scratchpad shadow `LoopWorkspace`: symlinks to every repo, a detached Loop worktree at upstream `next-dev` `e0eb9856`, and `Documentation/Loop/next-dev-host-integration.patch`, which applies cleanly. The main `LoopWorkspace/Loop` checkout is untouched; it has another session's uncommitted redesign work on it. The `xcodebuild … -scheme LoopWorkspace` build succeeded. The compiled `GlookoServiceKitUI.framework/Assets.car` lists only `Glooko`, and `GlookoBuild.plist` reads `3d0ec3f`, dirty.

I captured on the `loop` simulator with `tools/phone-control` and `simctl io screenshot` at 1206 × 2622, with the status bar overridden to 09:41. As before, the email is covered by a plain rounded bar, drawn by a small CoreGraphics tool in the session scratchpad at x 92, y 696, 800 × 60. The bar is grey 229/229/234 in light mode, 58/58/60 in dark mode, and 183/183/187 under the alert's dimming. Insulin was switched on only for `alert.png` and `insulin-on.png`; afterwards the switch reads value 0 and the header reads *Up to date*.

I left the other nine images alone. None of them shows the icon, but they still show the redesign strip at the top edge. The provenance file says so. Recapturing them, including the sign-in screens and a fresh live check, is a possible follow-up.

## Coordination

My first install on `loop` replaced another session's redesign build in the middle of its test run. That session (`loop-b4`) asked me to hold off. I stopped, told it what state I had changed, and resumed when it said it was finished. It warned that a Pump Simulator bolus given shortly before a reinstall can drop out of Loop's history, so IOB on `loop` shouldn't be trusted across these installs. The simulator now runs my plain `next-dev` build; `loop-b4` said it doesn't need its build reinstalled.

## Slips

- The first status run tapped through Loop's "Turn On Alarms" dialogue. I added a Close tap and it was fine after that.
- Tapping the insulin switch by identifier didn't toggle the SwiftUI `Toggle`. `tapXY` at 0.845, 0.40 did.

## Verification

- Visual: the header renders without the icon in light and dark mode, with insulin on, and under the alert.
- Full suite: `xcodebuild test -scheme GlookoServiceTests` ran in the shadow workspace on `loop`. The result was 20 tests with 1 failure: `testGlucoseDefaultsOnSupportsDexcomLibreAndPersistsOffWithoutLosingPendingReadings` at `ServiceUploadTests.swift:167`. There, `pendingGlucose` was 1, not 0, straight after the forced `uploadIfNeeded` that follows graph readback. `xcodebuild` then hung writing the result bundle (`IDESchemeActionSDKRecord … invalidDigitCount`) and I killed it.
- I reran that test alone three times with `-only-testing`: it passed every time, in about 7.3 s each.
- This change only touches `GlookoServiceKitUI` sources and assets and the project file's licence entries. The failing test exercises `GlookoServiceKit` glucose acknowledgement. So the failure is probably an intermittent timing problem in that test, not something this change caused, but I haven't confirmed that by running it at clean `3d0ec3f`. It's still open.
- Garry asked for the repository to be updated, so this change and entry were committed together to `main` and pushed. The parent repo then records the new pointer.
