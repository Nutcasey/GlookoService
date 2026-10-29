# Screenshot provenance

All images were captured on **29 October 2026** on the existing Device Hub simulator **loop** (iPhone 18 Pro, iOS 27.0), using `xcrun simctl io … screenshot` at native resolution (1206 × 2622). They are real GlookoService screens inside Loop. They replace the earlier set, which predated the redesigned settings screens.

The app was built with Xcode 27.1 from GlookoService **`785b753`**, a clean build (the Help section shows `785b753` with no `.dirty` suffix). The host source was Loop `415926dd` plus the [documented next-dev host patch](../Loop/next-dev-host-integration.patch). The simulator uses the Pump Simulator, the CGM Simulator and synthetic Loop history. The signed-in screens use an isolated Glooko test account, with its password saved on the simulator.

## Edits

Only one edit was made. In `status.png`, `status-dark.png`, `insulin-on.png` and `alert.png`, the test account's email address in the status header is covered by a plain rounded bar. Nothing else is composited, redrawn, cropped or retouched. The sign-in screens show empty fields because the email was cleared before capture and then cancelled. No password, session cookie or credential appears in any image.

## What the images do and don't show

- Simulator insulin is excluded by design. `insulin-on.png` and `alert.png` show insulin switched on only to demonstrate that guard. Insulin was switched off again straight after capture.
- CGM Simulator readings are also excluded, so the glucose rows read *Not yet* and the diagnostics show zero expected readings. Positive glucose and insulin transfers are recorded under Verification in the [README](../../README.md).
- The live check in `diagnostics.png` (20:11:09) compared **zero** confirmed insulin entries. It shows that authenticated readback works, not that clinical insulin was transferred.
- These are plugin screens. They do not show or certify Glooko's own Daily log layout.

| Image | Shows | SHA-256 |
|---|---|---|
| [services.png](services.png) | Glooko listed under Loop Settings → Services | `7244e933926f2a947ff8ea956d7b706207086fe868f41766881e3f4abd68d20f` |
| [setup.png](setup.png) | Sign-in: account fields, saved-password option and what to send | `04943cd24da8a9e0ab0cb8c087ea4533dc3343e8a27edec949871bde9fe0a99f` |
| [setup-options.png](setup-options.png) | Sign-in: mobile data, Sign in and Cancel | `4ff9641e9c580f20333ba19db4c3422ded9c369893e154ccbcccba03f070413d` |
| [status.png](status.png) | Status header *Up to date*, insulin off, glucose on | `bc71eebd5c4eeae505b9187502e1f0aade1625b1ee128e5d1e79d02e89eb88ef` |
| [status-dark.png](status-dark.png) | The same screen in dark mode | `f8ad81fe125dcb4c9869d93904df1eca61fd27f62fc69ee59dc380ce39938f6d` |
| [insulin-on.png](insulin-on.png) | Insulin rows with the simulator-pump guard warning | `2d01889cd681df2bf37dd90c9aa56cb863aa604e42017903d76efa47a0dfb20e` |
| [alert.png](alert.png) | The Loop alert raised when insulin can't be sent | `3e4ac33465b11e87ca802d98e3f616674a81ae28a3103edebe495186fbe00d8d` |
| [sending.png](sending.png) | Carbs, then Sending (Send now, mobile data, Alert after, test alert) | `efecd77358290fb1a8386289e19ffaa74c21ca080b2feefca92c49b68e710c12` |
| [account.png](account.png) | Account, Help (diagnostics, build) and Delete | `5c43438fcac72a01cbf02ac48f51d7dc4aa327e6e298e13bbbe479b7e091c332` |
| [delete.png](delete.png) | The delete choice: keep or erase local history | `d5567f6a676157228823afd6fe97d83e394297e346c6581ddd9e2016a09dc99b` |
| [diagnostics.png](diagnostics.png) | Check Glooko now result and the Insulin section | `b68af790dbc1584a62b007f2bdd2cf0c550baad889ed884475e80aab8f81770b` |
| [diagnostics-glucose.png](diagnostics-glucose.png) | Glucose readback counts, Carbs and settings | `f25506bff75a8603c094046025d012b11423a6d7d8d3c0df93b6927998721608` |
| [diagnostics-activity.png](diagnostics-activity.png) | Finding data in Glooko and Recent activity | `4a3a54eace9a536f4b8f29e6229a1e69f40f6f8737c8def57060e2c54b7bcff2` |
