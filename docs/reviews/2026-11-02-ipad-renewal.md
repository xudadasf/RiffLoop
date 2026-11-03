# iPad renewal: USB metadata error and wireless setup

## Findings

- Reproduced `TypeError: Object of type bytes is not JSON serializable` with binary app metadata. The device connection can succeed while JSON encoding fails. Export only RiffLoop version, bundle and signer fields.
- Device read on 2026-11-02 confirmed RiffLoop **0.25.68 (112)** over USB. Wireless connection setting was enabled through the trusted USB connection and read back successfully. This did not reinstall the app.
- The renewal checkout lacked the original IPA. Retrieved successful [IPA build #115](https://github.com/xudadasf/RiffLoop/actions/runs/40483849404), commit `0e64a1a64b9b8bb7e421cc75079736b210ad1c47`, with SHA-256 `e04620a2a380bfeeee03892e4219892bb0b9592755311812357ae5d6cf08602d`. It matches the release manifest from the previous installation.
- USB renewal dry-run passed device/version/package checks. No signing or installation has been performed during these checks.
- Latest diagnostic while connected: USB 1, Apple wireless devices 0, mDNS advertisements 0; Apple Mobile Device Service running. This does not establish a router, band or firewall fault. Unplugged wireless discovery and an actual wireless renewal remain to be verified.

## Unplugged follow-up

- USB 0 / Network 0 after unplugging reproduced the failure. A unicast mDNS query bound to the physical WLAN address received an Apple device response; a direct read verified the original iPad identity. The default mDNS probe returned zero in this multi-adapter environment, so its absence result must not be treated as proof of network isolation.
- Bonjour Service was absent. Installed only Bonjour from the [Apple official package](https://support.apple.com/106380), verifying both the download and MSI Authenticode signatures. MSI exited 0 and Bonjour Service was running.
- Restarted Apple Mobile Device Service. **USB 0 / Network 1**, then the Network-only renewal dry-run read the original app's 0.25.68 (112) and passed package validation. No router, VPN or broad firewall settings were changed.
- The first actual renewal attempt was interrupted before Start by Sideloadly's automatic update/restart. Subsequent discovery saw no wireless device; requested that the user keep the iPad unlocked and awake for another attempt. Actual signing/install success remains unverified at this point.
- Added missing/stopped Bonjour guidance and an explicit updater-restart message. Do not infer successful renewal from a discovery check or a successful process exit alone.
- Further checks still received a physical-WLAN mDNS response while Apple Network discovery was zero. Stopped the hidden iTunes instance launched for this investigation and restarted Bonjour and Apple Mobile Device Service. Bonjour then bound the physical WLAN discovery socket, but Network discovery did not immediately recover. Missing Bonjour alone did not explain every later disappearance.

## Pairing and Sideloadly follow-up

- Sideloadly's repair-pairing action invalidated the prior pairing. After the user confirmed trust, a new pairing was accepted but Apple Mobile Device Service returned error 183 while saving over its existing record. All three stored records initially failed validation; after pairing, the local record validated while the Apple service's record did not.
- Replaced only this iPad's stale Apple pairing record with the independently validated new record and restarted the service. A backup of the previous record remains in the protected Apple pairing directory because automated cleanup was blocked. USB and Network reads then both returned the original 0.25.68 (112) app; Network dry-run also passed after USB was unplugged. No iPad VPN was active; the computer's VPN was retained.
- Sideloadly 0.72 displays an account suffix such as `[10 App IDs Remaining]`. The old exact comparison rejected the actual original account. The check now removes only this known suffix before comparing the entire account; tests cover the current display and rejection of other or misleading accounts.
- On 2026-11-03, with USB unplugged, Sideloadly selected the original iPad over Wi-Fi and installed RiffLoop 0.25.68 (112). The device still reported the original bundle and `ProfileValidated=true`. A matching profile created at 09:20 Beijing time expires on 2026-11-10 at 09:20 Beijing time; the user confirmed that the app's displayed expiry was updated. Sideloadly's RiffLoop automatic-refresh record was updated at 09:20 with `one_off=0`.
- The original completion check falsely reported failure because it expected `Installing 100%: Complete`, whereas both the current and older actual logs say `Installing: 100% Complete`. It also stopped waiting on `Done work`. The check now recognizes either explicit completion format, waits for that confirmation and rejects `Done work` alone. Synthetic regression cases and the real completed log passed; the app was not installed a second time for this check.

## Changes and validation

- Explicit Network/USB selection, bounded discovery wait, original-device verification and useful original probe errors.
- USB fallback only after a connection probe failure; package/account/signing failures stop the operation.
- Desktop wireless setup entry plus read-only `-DiagnoseWifi`; preserve original app identity and version.
- Seven Python regression tests passed, including binary metadata, transport selection, delayed discovery, ambiguous devices and wireless setup restrictions. PowerShell parsing and `git diff --check` passed.

See [renewal instructions](../IPAD_SIDELOAD.md). Pairing records, account details and device dumps are intentionally not included here.
