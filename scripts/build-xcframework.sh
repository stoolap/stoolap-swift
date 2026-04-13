#!/usr/bin/env bash
# Copyright 2025 Stoolap Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Build StoolapC.xcframework for all Apple platforms.
#
# Targets:
#   - macOS (arm64 + x86_64)
#   - iOS device (arm64)
#   - iOS simulator (arm64 + x86_64)
#
# Prerequisites:
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin \
#     aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Usage:
#   scripts/build-xcframework.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$ROOT_DIR/crates/stoolap-c"
HEADERS="$ROOT_DIR/Sources/CStoolap/include"
OUTPUT="$ROOT_DIR/StoolapC.xcframework"
TMP_DIR="$(mktemp -d)"

TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 1. Build static library for each target
for target in "${TARGETS[@]}"; do
  echo "==> Building $target"
  cargo build --release --target "$target" --manifest-path "$CRATE_DIR/Cargo.toml"
done

# 2. Create universal (fat) libraries
echo "==> Creating macOS universal binary"
lipo -create \
  "$CRATE_DIR/target/aarch64-apple-darwin/release/libstoolap_c.a" \
  "$CRATE_DIR/target/x86_64-apple-darwin/release/libstoolap_c.a" \
  -output "$TMP_DIR/macos-libstoolap_c.a"

echo "==> Creating iOS simulator universal binary"
lipo -create \
  "$CRATE_DIR/target/aarch64-apple-ios-sim/release/libstoolap_c.a" \
  "$CRATE_DIR/target/x86_64-apple-ios/release/libstoolap_c.a" \
  -output "$TMP_DIR/ios-sim-libstoolap_c.a"

# 3. Assemble xcframework
echo "==> Creating xcframework"
rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -library "$TMP_DIR/macos-libstoolap_c.a" \
  -headers "$HEADERS" \
  -library "$CRATE_DIR/target/aarch64-apple-ios/release/libstoolap_c.a" \
  -headers "$HEADERS" \
  -library "$TMP_DIR/ios-sim-libstoolap_c.a" \
  -headers "$HEADERS" \
  -output "$OUTPUT"

echo
echo "Done. Output: $OUTPUT"
du -sh "$OUTPUT"
