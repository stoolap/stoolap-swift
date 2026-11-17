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

import os

/// Serializes calls on one engine handle.
///
/// A `StoolapDB` or `StoolapStmt` keeps its last error on the handle, and
/// the engine does not allow two threads in one handle at once, so calls
/// on a shared handle are serialized. The lock lives in its own allocation
/// so its address never moves.
@usableFromInline
final class HandleLock: @unchecked Sendable {
    @usableFromInline
    let raw: UnsafeMutablePointer<os_unfair_lock>

    init() {
        raw = .allocate(capacity: 1)
        raw.initialize(to: os_unfair_lock())
    }

    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }

    @inlinable
    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(raw)
        defer { os_unfair_lock_unlock(raw) }
        return try body()
    }
}
