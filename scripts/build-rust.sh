#!/usr/bin/env bash
# Copyright 2025 Stoolap Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Build the Rust cdylib that the Swift package links against.
#
# Usage:
#   scripts/build-rust.sh           # release build (default)
#   scripts/build-rust.sh debug     # debug build
#
# After this script runs, `swift build` and `swift test` will pick up the
# library from crates/stoolap-c/target/release/libstoolap_c.{dylib,a}.

set -euo pipefail

PROFILE="${1:-release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$ROOT_DIR/crates/stoolap-c"

echo "==> Building stoolap-c ($PROFILE)"
cd "$CRATE_DIR"

if [[ "$PROFILE" == "release" ]]; then
    cargo build --release
    OUT_DIR="$CRATE_DIR/target/release"
else
    cargo build
    OUT_DIR="$CRATE_DIR/target/debug"
fi

echo "==> Built artifacts:"
ls -lh "$OUT_DIR" | grep -E 'libstoolap_c\.(dylib|a)' || true

echo
echo "Done. Run 'swift test' from $ROOT_DIR to exercise the driver."
