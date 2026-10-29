# 261029-1508 - Identify Loop honestly and remove unnecessary Glooko app metadata

Pete Schwamb questioned the copied Glooko iOS user agent, fabricated `deviceInformation` and website Origin/Referer. Inspection confirmed that `GlookoClient` added a Glooko app version, build, Git hash, OS/device description, random device ID and derived serial to every request, and repeated the metadata in login bodies. Origin/Referer were confined to the retained legacy file-upload helper; the active insulin/food writers did not add them.

## Evidence before the change

Used the existing isolated EU test account, retrieving its password from Keychain into process memory. A minimal v3 sign-in containing only the user credentials and an honest Loop-GlookoService user agent returned HTTP 200 and a session. An authenticated users request then verified the expected test account. Neither request sent deviceInformation, Origin or Referer. This established that app impersonation was unnecessary for that account's login/read path; the full production writer was checked next rather than inferring upload compatibility from login alone.

## Implementation

- Identify requests as `Loop-GlookoService (+https://github.com/Nutcasey/GlookoService)`, with no invented product version or system string.
- Remove deviceInformation from headers and both login shapes. Remove its construction, the deviceId initialiser parameter and the extraction-interface environment override. There were no production callers supplying that parameter.
- Retain credential-only v3 user and v2 userLogin fallbacks. Removing metadata made the two previous v3 variants identical, so retain only one. Credential/account rejection, MFA, cookie validation, cancellation and redirect refusal retain their existing safeguards.
- Remove website Origin/Referer from the legacy file helper as well. Keep the actual binary Content-Type. That helper is not used by the active insulin/food routes.
- Document the request identity, actual verification scope and the API's unofficial status in the README.

## Operated before official tests

Compiled the actual modified GlookoKit with a temporary driver under the parent's ignored `Repos/glooko-client-identity`. The driver signed in, verified the allowlisted test account, scanned baseline insulin and foods, and saved only its new probe GUIDs before any write. It submitted one synthetic basal and one bolus through production submitInsulin, created and amended one carb through submitCarbs, replayed the insulin without duplicates and independently verified both insulin records. Both sync-complete requests and exact record readbacks succeeded with the honest identity. No Glooko-app metadata or browser headers were restored as a fallback.

Cleanup confirmed both insulin deletions and the food deletion, then compared every pre-existing insulin and food record with the baseline: unchanged, with no unexpected new identities. Credentials and session values were never printed or stored in the evidence logs. No real patient account or phone was used. The legacy file route was checked at the outgoing-request boundary only, not with a live virtual-device upload.

## Regression, review and publication

Extended the existing authentication suite with one identity contract at the outgoing URLRequest boundary, covering login, reads, insulin/food writes and the legacy binary helper. It checks the honest user agent, absent impersonation headers/login metadata and correct cookie use. In an isolated checkout of the previous code it failed for the copied user agent, deviceInformation and browser headers. Updated the existing fallback cases for two credential-only shapes per host without weakening their rejection/MFA/cancellation checks. This protects a protocol/privacy contract, not a source layout, and adds no production test seam.

- Final `swift test --package-path GlookoService`: **40 tests passed**.
- Compiled all actual GlookoKit source for arm64 iOS Simulator, deployment target 17.6, Swift 5: succeeded with no diagnostics.
- README relative links and `git diff --check`: passed.
- Code-reviewer-cx review of the transport, callers, legacy helper, tests and documentation found no outstanding high-confidence issue.

Publish on the canonical main branch under Garry's existing instruction to update the service repository there. This change is not installed on the Ultimate iPhone; its earlier app build still contains the earlier transport. The host/adapter APIs and therapy behaviour are not changed by this slice.
