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

/// Builds a stack-allocated array of `StoolapValue` C structs from Swift
/// `[Value]` and calls `body` with `(pointer, count)`. Designed for zero
/// heap allocations on the hot path.
///
/// `withBoundParams` handles all the lifetime juggling needed when text
/// parameters carry pointers into Swift `String` storage: it calls
/// `withCString` on each text param, captures the returned pointers, and
/// keeps everything alive until the closure returns.
@usableFromInline
enum ParameterBinder {
    /// Stack-allocated capacity for the StoolapValue array. Covers the
    /// vast majority of real SQL parameter lists. Larger lists fall back
    /// to a heap allocation.
    @usableFromInline
    static let STACK_PARAM_CAPACITY = 16

    /// Bind `params` to a `StoolapValue` array and call `body`. The pointer
    /// is valid only inside the closure.
    @inlinable
    static func withBound<R>(
        _ params: [Value],
        _ body: (UnsafePointer<StoolapValue>?, Int32) throws -> R
    ) throws -> R {
        if params.isEmpty {
            return try body(nil, 0)
        }

        let count = params.count

        // Fast path: small param lists. Allocate the StoolapValue array on
        // the stack and recurse into the text-binding helper.
        if count <= STACK_PARAM_CAPACITY {
            return try withUnsafeTemporaryAllocation(
                of: StoolapValue.self,
                capacity: count
            ) { (slot: UnsafeMutableBufferPointer<StoolapValue>) -> R in
                try bindRecursive(params, index: 0, slot: slot, body)
            }
        }

        // Slow path: very long param lists go through a heap allocation.
        let storage = UnsafeMutableBufferPointer<StoolapValue>.allocate(capacity: count)
        defer { storage.deallocate() }
        return try bindRecursive(params, index: 0, slot: storage, body)
    }

    /// Recursively walk the param list, calling `withCString` on each text
    /// value to obtain a pointer that lives only for the duration of the
    /// closure. The recursion preserves the nested closure scopes that
    /// keep the underlying String storage alive.
    @inlinable
    static func bindRecursive<R>(
        _ params: [Value],
        index: Int,
        slot: UnsafeMutableBufferPointer<StoolapValue>,
        _ body: (UnsafePointer<StoolapValue>?, Int32) throws -> R
    ) throws -> R {
        if index == params.count {
            return try body(slot.baseAddress, Int32(params.count))
        }

        let value = params[index]
        switch value {
        case .null:
            slot[index] = StoolapValue(value_type: STOOLAP_TYPE_NULL,
                                       _padding: 0,
                                       v: StoolapValueData(integer: 0))
            return try bindRecursive(params, index: index + 1, slot: slot, body)

        case let .integer(i):
            slot[index] = StoolapValue(value_type: STOOLAP_TYPE_INTEGER,
                                       _padding: 0,
                                       v: StoolapValueData(integer: i))
            return try bindRecursive(params, index: index + 1, slot: slot, body)

        case let .float(f):
            slot[index] = StoolapValue(value_type: STOOLAP_TYPE_FLOAT,
                                       _padding: 0,
                                       v: StoolapValueData(float64: f))
            return try bindRecursive(params, index: index + 1, slot: slot, body)

        case let .boolean(b):
            slot[index] = StoolapValue(value_type: STOOLAP_TYPE_BOOLEAN,
                                       _padding: 0,
                                       v: StoolapValueData(boolean: b ? 1 : 0))
            return try bindRecursive(params, index: index + 1, slot: slot, body)

        case let .timestamp(date):
            let nanos = Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
            slot[index] = StoolapValue(value_type: STOOLAP_TYPE_TIMESTAMP,
                                       _padding: 0,
                                       v: StoolapValueData(timestamp_nanos: nanos))
            return try bindRecursive(params, index: index + 1, slot: slot, body)

        case let .text(s):
            // String storage must outlive the FFI call. withCString gives
            // us a pointer that's valid for the duration of the closure;
            // we recurse into the next parameter from inside that scope.
            // Use s.utf8.count (O(1)) instead of strlen (O(n)).
            let len = Int64(s.utf8.count)
            return try s.withCString { cstr in
                slot[index] = StoolapValue(
                    value_type: STOOLAP_TYPE_TEXT,
                    _padding: 0,
                    v: StoolapValueData(text: StoolapTextData(ptr: cstr, len: len))
                )
                return try bindRecursive(params, index: index + 1, slot: slot, body)
            }

        case let .json(s):
            let len = Int64(s.utf8.count)
            return try s.withCString { cstr in
                slot[index] = StoolapValue(
                    value_type: STOOLAP_TYPE_JSON,
                    _padding: 0,
                    v: StoolapValueData(text: StoolapTextData(ptr: cstr, len: len))
                )
                return try bindRecursive(params, index: index + 1, slot: slot, body)
            }

        case let .blob(data):
            return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
                let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                slot[index] = StoolapValue(
                    value_type: STOOLAP_TYPE_BLOB,
                    _padding: 0,
                    v: StoolapValueData(blob: StoolapBlobData(ptr: bytes, len: Int64(raw.count)))
                )
                return try bindRecursive(params, index: index + 1, slot: slot, body)
            }

        case let .vector(floats):
            // Vectors travel as packed f32 bytes through the BLOB tag.
            // The Rust side distinguishes "empty vector" (non-NULL ptr,
            // len=0) from "null" (NULL ptr), so we always allocate at
            // least one byte to keep the pointer non-NULL.
            let byteCount = floats.count * 4
            let allocBytes = max(byteCount, 1)
            return try withUnsafeTemporaryAllocation(
                byteCount: allocBytes,
                alignment: 4
            ) { (raw: UnsafeMutableRawBufferPointer) -> R in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                if byteCount > 0 {
                    var off = 0
                    for f in floats {
                        let bits = f.bitPattern.littleEndian
                        withUnsafeBytes(of: bits) { src in
                            for i in 0 ..< 4 {
                                base[off + i] = src[i]
                            }
                        }
                        off += 4
                    }
                }
                slot[index] = StoolapValue(
                    value_type: STOOLAP_TYPE_BLOB,
                    _padding: 0,
                    v: StoolapValueData(blob: StoolapBlobData(ptr: base, len: Int64(byteCount)))
                )
                return try bindRecursive(params, index: index + 1, slot: slot, body)
            }
        }
    }
}
