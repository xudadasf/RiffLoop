# 0.25.70 wireless installation — 2026-11-03

User explicitly requested script-driven wireless installation. The initial Network probes found no iPad despite Bonjour advertisements. After the user unlocked the device, one restart of Apple Mobile Device Service restored Network discovery without changing pairing records. The device read confirmed 0.25.68 (112) and the original signed application.

The first installer attempt selected the correct Wi-Fi device but stopped before Start because account validation rejected a new Sideloadly label suffix: `[9 App IDs Remaining, updates 6d]`. UI inspection confirmed the original account. A regression reproduced the false rejection, then the exact known suffix grammar was extended; full account comparison remains mandatory. Ten account cases and six install-completion cases passed. The fix is committed in the existing wireless-helper checkout as `8d46db147e0ca0b5afaecbc1ebd0857b1a0968d9` on `codex/pdf-tab-prototype-20261006`. The helper commit also passed [iOS CI 41567507794](https://github.com/xudadasf/RiffLoop/actions/runs/41567507794). The iPad application code is unchanged from the verified product commit.

The second scripted attempt completed over Wi-Fi at 2026-11-03 10:40 Beijing time. Sideloadly reported `Installing: 100% Complete`. Its automatic-refresh record is 0.25.70 with `one_off=0`. Independent Network readback confirmed 0.25.70 (114), the original signed bundle and signer, and `ProfileValidated=true`.

All 14 Documents files (169,785,536 bytes) have identical before/after SHA-256 hashes. The first post-install hash read was interrupted by a wireless disconnect; reconnecting and using 256 KiB reads completed the comparison. No device file backup was saved locally.

Five preference payload hashes changed: the GP mode settings, recent-project state, daily practice history, one per-score profile and last-project state. Current preferences include the new `trackTimbres` field and a November 3 practice entry; earlier history remains readable from August 21 onward. Only payload hashes were retained in the pre-install baseline, so this is not a claim that every historical duration or preference value is byte-identical. The installer did not clear preferences or uninstall the app. Actual tone listening remains user validation.

The completed Sideloadly window was closed normally; its refresh daemon and managed renewal cache are preserved. The downloaded unsigned IPA, its staging manifest and the temporary installer wrapper/log/result were removed. A subsequent cleanup command for six TEMP files and the two now-empty staging directories was rejected by automatic approval with only `blocked by policy`; no part of that command ran and it was not bypassed. Earlier cleanup refusals for unrelated test directories remain separate and were not bypassed.


Remaining files for manual cleanup (only this installation attempt):

- `C:/Users/sadada/AppData/Local/Temp/sideloadly-install-20261103-103356.log` and `.log.err`.
- `C:/Users/sadada/AppData/Local/Temp/sideloadly-install-20261103-103911.log` and `.log.err`.
- `C:/Users/sadada/AppData/Local/Temp/sdl-verify-20261103-104017.db` (temporary database copy, not the Sideloadly live database).
- `C:/Users/sadada/AppData/Local/Temp/sdl-verify.py`.
- Empty worktree directories `output/release-0.25.70-build114-097a9cb/` and `output/install-02570-wireless/`.

The managed Sideloadly renewal record/cache is retained. The task no longer has a local unsigned IPA copy; a future script-based manual renewal that expects `output/release-*` must retrieve the verified package again. Do not delete the live Sideloadly database or its managed cache.
