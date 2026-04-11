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

// Resolve the absolute path to the Rust build artifacts so SPM can link
// against the cdylib produced by `scripts/build-rust.sh`.
//
// The Rust crate lives at `crates/stoolap-c/` and emits its dylib into
// `crates/stoolap-c/target/release/`. We pass that directory to the linker
// via `unsafeFlags` and link `-lstoolap_c`.
let rustReleaseDir = "\(Context.packageDirectory)/crates/stoolap-c/target/release"

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
        // C interop module exposing the hand-written stoolap.h header.
        .systemLibrary(
            name: "CStoolap",
            path: "Sources/CStoolap"
        ),

        // Swift driver. Links against the Rust cdylib (libstoolap_c.dylib)
        // built into crates/stoolap-c/target/release/ by scripts/build-rust.sh.
        .target(
            name: "Stoolap",
            dependencies: ["CStoolap"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", rustReleaseDir,
                    "-lstoolap_c",
                    "-Xlinker", "-rpath",
                    "-Xlinker", rustReleaseDir,
                ])
            ]
        ),

        .testTarget(
            name: "StoolapTests",
            dependencies: ["Stoolap"]
        ),
    ]
)
