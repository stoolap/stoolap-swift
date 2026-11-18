// swift-tools-version:5.9
// Copyright 2025 Stoolap Contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import PackageDescription

// Consumers link the prebuilt StoolapC.xcframework (static engine library
// for macOS and iOS) attached to each GitHub release. The release workflow
// rewrites `engineURL` and `engineChecksum` when it publishes a version.
let engineURL = "https://github.com/stoolap/stoolap-swift/releases/download/v0.5.0/StoolapC.xcframework.zip"
let engineChecksum = "6ae8929556aa35ee687cebad8485465378cf2c76db8a6255f5fd4057ba20db3a"

// Development builds the engine from source instead: run
// `scripts/build-rust.sh`, then build with STOOLAP_LOCAL_BUILD=1. That
// links the cdylib in crates/stoolap-c/target/release.
let localBuild = Context.environment["STOOLAP_LOCAL_BUILD"] == "1"
let rustReleaseDir = "\(Context.packageDirectory)/crates/stoolap-c/target/release"

let engineTarget: Target = localBuild
    // C interop module exposing the hand-written stoolap.h header.
    ? .systemLibrary(name: "CStoolap", path: "Sources/CStoolap")
    : .binaryTarget(name: "CStoolap", url: engineURL, checksum: engineChecksum)

let engineLinkerSettings: [LinkerSetting] = localBuild
    ? [.unsafeFlags(["-L", rustReleaseDir, "-lstoolap_c",
                     "-Xlinker", "-rpath", "-Xlinker", rustReleaseDir])]
    // The system libraries the static Rust library needs
    // (`cargo rustc -- --print native-static-libs`).
    : [.linkedFramework("CoreFoundation"), .linkedLibrary("iconv")]

let package = Package(
    name: "Stoolap",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "Stoolap",
            targets: ["Stoolap"]
        ),
    ],
    targets: [
        engineTarget,

        // Swift driver over the engine's C ABI.
        .target(
            name: "Stoolap",
            dependencies: ["CStoolap"],
            linkerSettings: engineLinkerSettings
        ),

        .testTarget(
            name: "StoolapTests",
            dependencies: ["Stoolap"]
        ),
    ]
)
