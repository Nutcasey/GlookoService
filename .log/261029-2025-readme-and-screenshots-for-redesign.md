# 261029-2025 - Rewrite the README and recapture every screenshot for the redesigned screens

Garry asked for the settings redesign to be committed as the latest update. He also asked for new photos and a comprehensive README covering every feature. The redesign itself was committed first as `785b753`, so the screenshots could come from a clean build; Help → Build shows `785b753` with no `.dirty` suffix. This entry covers the documentation commit that follows.

## Screenshots

I built `785b753` for the `loop` simulator, installed it and captured 13 native 1206 × 2622 PNGs with `simctl io screenshot`, driven by `tools/phone-control` via a small helper in the ignored `Repos/glooko-readme-shots/`. They cover:
- the services list;
- sign-in and its options;
- the status screen in light and dark mode;
- insulin switched on with the simulator-pump guard, and the matching Loop alert;
- Sending, Account/Help/Delete and the delete dialogue;
- three diagnostics views after a fresh read-only Check Glooko now at 20:11:09.

These replace `setup`, `setup-options`, `status` and `diagnostics`. `glucose.png` was removed because the new status image shows the Glucose section.

Decisions:
- **Account email.** The redesigned header shows it, and earlier documentation deliberately kept it out of public images. In the four status images it is covered by a plain rounded bar, drawn with a small CoreGraphics tool in the session scratchpad. This is the only edit and the provenance file says so. I chose a redaction over a code change, such as a hide-email option, because a code change would have altered the product for the sake of documentation.
- **Empty sign-in fields.** On the sign-in screen I cleared the email field before capture and then tapped Cancel, so the stored account was unchanged. The status screen afterwards still showed the same account and *Up to date*.
- **Simulator state restored.** Insulin was switched on only for the guard images, then off again. Its value was 0 and the header read *Up to date* afterwards.
- **No clinical images.** No images came from the clinical phone, which keeps the earlier rule that public docs use only the isolated account.

Slips:
- A downward drag on the sign-in sheet dismissed the whole Glooko sheet. That frame became `services.png`; nothing was submitted.
- The capture helper's failure check matched the label "Missing in Glooko". It now matches "Missing element".
- Taps landed mid-text in the email field until I tapped past its end.

## README

I restructured the README around what a user sees:
- a status screenshot pair at the top;
- what is sent;
- install;
- connecting the account;
- a section-by-section guide to the Glooko screen, including a table of status-header states;
- diagnostics and how to read Check Glooko now;
- alerts.

The technical sections follow. Every UI label was updated to the redesigned wording, for example *Send insulin*, *Use mobile data*, *Save password on this iPhone*, *Send now*, *Alert after*, *Change account or sign-in options* and *Delete and keep local history*. "Omnipod 5 via Loop on the status page" became the **Pump** row. I added *UI conventions*, which covers the single warning style, the red-only-for-warnings rule and the stable accessibility identifiers. Verification gained the redesign's simulator and phone results. The facts about routes, limits, identity and earlier verification were carried over unchanged. The screenshot provenance file was rewritten, with SHA-256 hashes for the new set.

Checks: every relative link and image path in both README files resolves, and `git diff --check` is clean. No code changed in this commit, so no tests were rerun. The 14/14 iOS service run from [261029-1909](261029-1909-settings-ui-clarity-pass.md) covers the code in `785b753` apart from its VoiceOver label line.

## State

- The Ultimate iPhone still runs the redesign as `c7964ee.dirty`. That build matches `785b753` except for the header VoiceOver label fix. It goes out with the next phone deploy.
- The simulator runs `785b753`, signed in with the password saved: insulin off, glucose on, mobile data off.
