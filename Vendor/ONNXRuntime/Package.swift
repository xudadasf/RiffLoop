// swift-tools-version: 5.9
import PackageDescription

// Same 1.24.2 runtime and bindings as the former upstream SPM dependency.
// The official Objective-C release sources are kept byte-for-byte; see provenance.json.
let package = Package(
    name: "onnxruntime",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [.library(name: "onnxruntime", type: .static, targets: ["OnnxRuntimeBindings"])],
    targets: [
        .target(name: "OnnxRuntimeBindings", dependencies: ["onnxruntime"],
                path: "objectivec", cxxSettings: [.define("SPM_BUILD")]),
        .binaryTarget(name: "onnxruntime", path: ".cache/onnxruntime-1.24.2.zip")
    ],
    cxxLanguageStandard: .cxx17
)
