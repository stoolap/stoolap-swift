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

import CStoolap
import Foundation

/// Binds a batch of `[Value]` rows into a single flat `StoolapValue`
/// array plus one shared arena for text and binary bytes, using
/// `ParameterBinder.bind` for each cell. This avoids per-cell heap
/// allocation churn in the hot batch-insert path.
@usableFromInline
enum BatchParameterBinder {
    @inlinable
    static func withBoundBatch<R>(
        _ batch: [[Value]],
        _ body: (UnsafePointer<StoolapValue>, Int32, Int32) throws -> R
    ) throws -> R {
        let width = batch[0].count
        let rowCount = batch.count

        var arenaBytes = 0
        for row in batch {
            arenaBytes += ParameterBinder.arenaSize(row)
        }

        let values = UnsafeMutableBufferPointer<StoolapValue>.allocate(capacity: max(rowCount * width, 1))
        defer { values.deallocate() }
        let arena = UnsafeMutableRawBufferPointer.allocate(byteCount: max(arenaBytes, 1), alignment: 4)
        defer { arena.deallocate() }

        var cursor = arena.baseAddress!
        for (r, row) in batch.enumerated() {
            for (c, value) in row.enumerated() {
                values[r * width + c] = try ParameterBinder.bind(value, arena: &cursor)
            }
        }
        return try body(UnsafePointer(values.baseAddress!), Int32(width), Int32(rowCount))
    }
}
