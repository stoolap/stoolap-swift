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

//! Thin cdylib shim around the official `stoolap::ffi` cursor API.
//!
//! This crate exists only to produce a `libstoolap_c.{dylib,a}` artifact
//! that the Swift package links against. All FFI symbols (`stoolap_open`,
//! `stoolap_query`, `stoolap_rows_next`, `stoolap_rows_column_*`, ...) are
//! defined inside the upstream `stoolap` crate behind feature `ffi` — we
//! just need to depend on it with that feature enabled so the linker
//! pulls the `#[no_mangle]` symbols into our cdylib.
//!
//! Re-exports below are not strictly necessary (the linker would emit the
//! symbols anyway thanks to `#[no_mangle]`), but they make the dependency
//! intent explicit and prevent rustc from dead-stripping the ffi module
//! if upstream ever changes its visibility rules.

#[allow(unused_imports)]
pub use stoolap::ffi::*;
