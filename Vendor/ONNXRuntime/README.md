# ONNX Runtime 1.24.2 build dependency

The upstream Swift-package Git repository returned 404 on 2026-11-18, preventing both simulator checks and device builds. This local package uses the same pinned 1.24.2 release, module name, static product, SPM header define, C++17 mode and official binary checksum. No runtime upgrade, OCR model or inference configuration change is included.

Unmodified Objective-C bindings and the MIT license come from Microsoft’s 1.24.2 Objective-C archive. The original archive checksums and the hashes of the vendored sources are recorded in `provenance.json`.

Before generating the Xcode project, run `python scripts/prepare-score-ocr.py`. It obtains the iOS XCFramework from Microsoft’s 1.24.2 NuGet package, verifies the NuGet catalogue SHA-512 and the embedded ZIP’s SHA-256, and places the ZIP in the package’s ignored build cache. This supports iPad devices and simulators after the original binary download became unavailable. [Microsoft.ML.OnnxRuntime 1.24.2](https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/1.24.2)

Run `python scripts/verify-onnx-package.py` to check vendored source integrity, or add `--archive path/to/official.zip` to compare every file byte-for-byte with the pinned archive. No user score is read. Keep the license in distributed app resources. Do not replace this dependency with an unverified mirror or a different runtime version as a download workaround.
