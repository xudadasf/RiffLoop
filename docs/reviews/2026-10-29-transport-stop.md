# Playback pause/stop investigation — 2026-10-29

User reports that playback controls cannot stop immediately and requests checks of GP, the independent metronome, PDF and video. Last verified installed build is 0.25.68 (112). No USB iPad was detected during this investigation, so there is no new device trace or physical output-latency measurement. Desktop UI remains user-operated.

## Reproduced GP defects

The bundled alphaTab `AlphaSynthWebWorkerApi.pause()` and `stop()` only post a worker message. RiffLoop previously waited for the worker's `output.pause` receipt to stop the local output. A deterministic harness uses the actual bundled worker API and production transport controller, holds worker receipts, and observes that the output remains running after both commands. This is a real asynchronous boundary absent from the older synchronous synth/controller tests; it is not evidence of the user's exact delay in milliseconds.

The same harness also reproduces a lost replay tap: after pause/stop, the cached worker state remains Playing, so `toggle()` sends another pause rather than play. Playback intent and observed worker state must not be interchangeable at this boundary.

Fix: pause/stop locally silences and pauses the installed Web Audio output before waiting for the worker, suppresses delayed output-play receipts and cursor sample receipts until the next explicit play, and restores output gain before count-in. Toggle uses the controller's playback intent. Existing generations still prevent old scheduled pause retries from affecting a new play. Native GP pause now stops its accompaniment immediately on the toolbar tap; stop updates `isPlaying` immediately as pause already did.

Regression covers 40 delayed-worker pause/stop/replay cycles, stale play receipts, output gain and cursor receipts, in addition to existing real synth count-in recovery, 50-round range restart, gain and follow tests. The new local-output assertion failed before the fix and passes after it. Physical device/DAC buffering cannot be measured by this harness.

A separate delayed-boundary regression also failed: after manual pause/stop cancelled the loop restarter, a queued non-seek position beyond B could invoke `handleCommittedRangeCompletion` and prepare another count-in loop. Range enforcement now requires current playback intent before initiating a new loop. It still processes the pending seek-to-A acknowledgement needed by active loops. The regression passes without weakening the existing 50-round restart/cancellation checks.

## Other transport paths

- Independent GP metronome: native `AVAudioPlayerNode.stop()` and timer/generation invalidation run in the stop path; it does not wait for the GP worker. Existing WKWebView integration exercises independence and switching back to score playback. No matching stop defect reproduced here.
- Video: pause cancels pending readiness, seeks and prerolls and advances the transport generation before stopping AVPlayer and the native metronome. Existing native tests cover cold-start cancellation and repeated video loops. Local policy checks pass; these checks alone are not acoustic latency measurements.
- PDF: follow, accompaniment and metronome have separate controls. Stopping established follow intentionally leaves independently running audio/metronome active. Two native regressions reproduce uncancelled starts: a second accompaniment tap while audio gain attaches still leads to playback; stopping follow during its initial seek still starts accompaniment and metronome. Both failed in CI 40808038757, including an observed AVPlayer rate of 1 after cancellation. Pending starts now have published request state, the next tap cancels them, and stop invalidates their seek/readiness callbacks. Existing independently running channels retain their separate controls.
- Diagnostics: file I/O and material hashing use background queues. No synchronous journal disk-write path was found ahead of pause/stop; this does not rule out an unrelated main-thread stall on the user's device.

## Delivery boundary

The first simulator run also exposed a paused-seek race in the GP integration test. A local Chromium reproduction using the real page, worker and soundfont showed `setTickPosition(3840)` followed by an unsolicited `setTickPosition(0)`: alphaTab's actual `zw` Paused callback snaps to the last beat. An explicit seek made before that receipt is now reapplied after it; the latest target wins and score loading clears it. The browser reproduction now retains tick 3841 (alphaTab's one-tick position rounding), and a Node regression invokes the real vendor pause callback. This preserves the pre-existing integration test rather than relaxing its assertion. Windows WebKit could render the score but did not reach player readiness; it was not used as passing playback evidence. Temporary tracing is removed.

Changes in this investigation have not been installed on the user's iPad. Keep USB reconnection paused pending manual play. No private device files have been downloaded in this investigation.


## Final validation record

CI [40811581756](https://github.com/xudadasf/RiffLoop/actions/runs/40811581756) ran 180 Swift tests: the actual WKWebView playback/recovery integration and both new PDF cancellation tests passed; the sole failure was the GP paused-page screen-awake check. Its exported screenshot shows the unloaded GP placeholder and disabled transport at the fixed four-second deadline. The screenshot test now waits (bounded to 20 seconds) for an actual score SVG before checking the original screen-awake assertion. It also asserts rendering readiness explicitly; the assertion and application screen-awake logic are unchanged. The old fixed sleep could check the no-score policy rather than the paused loaded-score policy.

Test-only commit `15fbe739afb73bde0c3e6261c12346244d69b41d` triggers final CI [40813473034](https://github.com/xudadasf/RiffLoop/actions/runs/40813473034), passed all 180 Swift tests (zero failures), playback-policy checks and release safety gates. The previously failing paused-page screenshot test passed after waiting for the actual rendered score. Its only difference from product commit `7f93577d86481611ef9305190af98bd9fd7c6f3a` is `RiffLoopTests/PracticeExperienceTests.swift`; the IPA application code remains identical.

IPA [40811585478](https://github.com/xudadasf/RiffLoop/actions/runs/40811585478) succeeded. Package version 0.25.69 (113), arm64 iPhoneOS binary, bundle identifier and exact GP JavaScript bytes were checked against the product commit entirely in memory, without writing an IPA/ZIP to disk. Hash and artifact expiry are in [build metadata](../releases/0.25.69-build-info.json). Temporary diagnostic scripts ran from stdin and were not saved. No installation or new device data collection occurred.

Prevention: exercise the actual asynchronous worker boundary with delayed receipts instead of relying only on synchronous controller mocks; wait for independently observed rendering readiness before asserting loaded-page policies. Verification records and source are pushed to Git. The working tree contains no newly downloaded installation packages or temporary diagnostic files. Physical iPad installation and output-latency verification remain pending.
