# Simulator screenshot provenance

Captured on **29 October 2026**, using the existing Device Hub simulator **loop**, an iPhone 18 Pro on **iOS 27.0**. These are actual GlookoService screens inside Loop, captured with `xcrun simctl io … screenshot` at native resolution. The PNGs have not been composited, redrawn, cropped or retouched.

The app was built with Xcode 27.1 from GlookoService `f0a9ce7`, with documentation changes in the working tree. The host source was Loop `415926dd` plus the [documented next-dev host patch](../Loop/next-dev-host-integration.patch). The build used the LoopWorkspace scheme and simulator destination; no global SDK override was used.

Setup fields are empty. The signed-in images use an isolated test account, with its account section scrolled off screen. Password recovery was left off. No password, session cookie or account e-mail is included in these images.

The simulator has synthetic Loop history. Insulin from simulator or unidentified pump sources is excluded by the production service. No real pump was paired, no identity was fabricated and no synthetic insulin was sent to the real account for these captures. The status image shows **zero confirmed insulin entries**. The successful check at **11:32:09 GMT** therefore demonstrates authenticated readback and source-query completion, not successful clinical insulin transfer.

These images show the plugin UI. They do not show Glooko’s own Daily log or establish its exact row wording. Glooko controls that presentation. The [README](../../README.md) documents the separately verified record-name contract and the limits of these checks.

| Image | Visible workflow | Native pixels | SHA-256 |
|---|---|---|---|
| [setup.png](setup.png) | Empty account fields, session recovery and default upload choices | 1206 × 2622 | `22651139588e405e768051f1a9dcab7b343e25e713e59858f66e42a45845c01e` |
| [setup-options.png](setup-options.png) | Upload choices, reporting start and sign-in controls | 1206 × 2622 | `c08186905076e1ed337aef613cf7cdc0adcf3eff7351fa74630f7bda94b33742` |
| [status.png](status.png) | Insulin queue, reporting period, Upload now and independent carb status | 1206 × 2622 | `01625bed3557bd052f0f748ca7ab63c0c197e3c678283152fc6264b8a3e780a1` |
| [diagnostics.png](diagnostics.png) | Dated read-only check, completed source queries and empty queues | 1206 × 2622 | `126b79aa01beb1521eef3dc6eaebf468063cf8256264e6b0613448251351d552` |
