# 261029-1956 - Sign the simulator test account back in, with its password saved

This follows [261029-1909](261029-1909-settings-ui-clarity-pass.md), which left the `loop` simulator's isolated test account signed out after its Glooko session expired.

Garry asked to be taken to the sign-in screen so he could sign in himself. I navigated the simulator to Settings → Glooko → *Change account or sign-in options* and opened Device Hub. Garry entered the password and signed in, with **Save password on this iPhone** turned on. The password never passed through this session. From now on the simulator signs itself back in when the session expires, which is the reason for saving it.

On the way to the sign-in screen, a retry of the phone-control script tapped *Send a test alert* by mistake. The alert says no failure is being reported and it sends no data. I dismissed it.

I verified the result on the status screen by reading the accessibility tree only, with no taps. The header reads *Up to date* and Account shows *Password: Saved on this iPhone*. The other options were unchanged: insulin off, glucose on, mobile data off.

## Small UI fix

The header's VoiceOver label was " Up to date", with a leading space left over from the inline symbol. It now uses `accessibilityLabel(health.title)`. After rebuilding and installing on the simulator, it reads "Up to date". This change is not yet on the Ultimate iPhone. It will go out with the next phone deploy.

## Open

Same as 261029-1909: the commit is pending Garry's say-so, and the README screenshots are out of date.
