# ONNX Runtime 1.24.2 build dependency

The upstream Swift-package Git repository returned 404 on 2026-11-18, preventing both simulator checks and device builds. This local package uses the same pinned 1.24.2 release, module name, static product, SPM header define, C++17 mode and official binary checksum. No runtime upgrade, OCR model or inference configuration change is included.

Unmodified Objective-C bindings and MIT license come from Microsoft's official [1.24.2 Objective-C archive](https://download.onnxruntime.ai/pod-archive-onnxruntime-objc-1.24.2.zip). Only upstream tests are omitted. `provenance.json` records the archive checksum and each included file's SHA-256. The binary target still downloads the official 1.24.2 C archive and SwiftPM verifies its fixed checksum, also present in the prior upstream package manifest.

Run `python scripts/verify-onnx-package.py` to check vendored source integrity, or add `--archive path/to/official.zip` to compare every file byte-for-byte with the pinned archive. No user score is read. Keep the license in distributed app resources. Do not replace this dependency with an unverified mirror or a different runtime version as a download workaround.
