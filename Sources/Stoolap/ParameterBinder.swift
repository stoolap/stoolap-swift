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

/// Builds the `StoolapValue` C structs for a `[Value]` parameter list and
/// calls `body` with `(pointer, count)`.
///
/// Text, JSON, blob and vector bytes are copied into one arena, so the
/// binding is a flat loop with no nested `withCString` scopes. The value
/// array and the arena come from `withUnsafeTemporaryAllocation`: on the
/// stack when small, on the heap when large, so a long parameter list is
/// safe on a thread with a small stack.
@usableFromInline
enum ParameterBinder {
    /// Bind `params` and call `body`. The pointer is valid only inside
    /// the closure.
    @inlinable
    static func withBound<R>(
        _ params: [Value],
        _ body: (UnsafePointer<StoolapValue>?, Int32) throws -> R
    ) throws -> R {
        if params.isEmpty {
            return try body(nil, 0)
        }
        let count = params.count
        return try withUnsafeTemporaryAllocation(
            of: StoolapValue.self,
            capacity: count
        ) { (slots: UnsafeMutableBufferPointer<StoolapValue>) -> R in
            try withUnsafeTemporaryAllocation(
                byteCount: max(arenaSize(params), 1),
                alignment: 4
            ) { (arena: UnsafeMutableRawBufferPointer) -> R in
                var cursor = arena.baseAddress!
                for i in 0 ..< count {
                    slots[i] = try bind(params[i], arena: &cursor)
                }
                return try body(UnsafePointer(slots.baseAddress), Int32(count))
            }
        }
    }

    /// Arena bytes `bind` uses for `params`.
    @inlinable
    static func arenaSize(_ params: [Value]) -> Int {
        var total = 0
        for value in params {
            total += arenaSpan(value)
        }
        return total
    }

    /// Arena bytes `bind` uses for `value`. Every span is at least one
    /// byte, so an empty text, blob or vector still gets a non-NULL
    /// pointer (the engine reads a NULL pointer as SQL NULL), and is
    /// rounded up to 4 so each vector stays 4-byte aligned.
    @inlinable
    @inline(__always)
    static func arenaSpan(_ value: Value) -> Int {
        switch value {
        case let .text(s), let .json(s):
            return (max(s.utf8.count, 1) + 3) & ~3
        case let .blob(data):
            return (max(data.count, 1) + 3) & ~3
        case let .vector(floats):
            return max(floats.count * 4, 4)
        default:
            return 0
        }
    }

    /// Convert one value, copying its bytes (if any) to `arena` and
    /// advancing it by `arenaSpan(value)`.
    @inlinable
    static func bind(_ value: Value, arena: inout UnsafeMutableRawPointer) throws -> StoolapValue {
        switch value {
        case .null:
            return StoolapValue(value_type: STOOLAP_TYPE_NULL, _padding: 0,
                                v: StoolapValueData(integer: 0))

        case let .integer(i):
            return StoolapValue(value_type: STOOLAP_TYPE_INTEGER, _padding: 0,
                                v: StoolapValueData(integer: i))

        case let .float(f):
            return StoolapValue(value_type: STOOLAP_TYPE_FLOAT, _padding: 0,
                                v: StoolapValueData(float64: f))

        case let .boolean(b):
            return StoolapValue(value_type: STOOLAP_TYPE_BOOLEAN, _padding: 0,
                                v: StoolapValueData(boolean: b ? 1 : 0))

        case let .timestamp(date):
            return StoolapValue(value_type: STOOLAP_TYPE_TIMESTAMP, _padding: 0,
                                v: StoolapValueData(timestamp_nanos: try timestampNanos(date)))

        case let .text(s):
            let text = copyText(s, arena: &arena)
            return StoolapValue(value_type: STOOLAP_TYPE_TEXT, _padding: 0,
                                v: StoolapValueData(text: text))

        case let .json(s):
            let text = copyText(s, arena: &arena)
            return StoolapValue(value_type: STOOLAP_TYPE_JSON, _padding: 0,
                                v: StoolapValueData(text: text))

        case let .blob(data):
            // The engine reads a BLOB parameter as packed f32 values and
            // stores any other length as NULL.
            guard data.count % 4 == 0 else {
                throw StoolapError(
                    ".blob is read as packed f32 values: its length must be a multiple of 4 bytes, got \(data.count)"
                )
            }
            let dest = arena.assumingMemoryBound(to: UInt8.self)
            data.copyBytes(to: dest, count: data.count)
            arena += arenaSpan(value)
            return StoolapValue(value_type: STOOLAP_TYPE_BLOB, _padding: 0,
                                v: StoolapValueData(blob: StoolapBlobData(ptr: dest, len: Int64(data.count))))

        case let .vector(floats):
            // Vectors travel as packed little-endian f32 bytes through the
            // BLOB tag.
            let dest = arena.assumingMemoryBound(to: UInt8.self)
            var off = 0
            for f in floats {
                (arena + off).storeBytes(of: f.bitPattern.littleEndian, as: UInt32.self)
                off += 4
            }
            arena += arenaSpan(value)
            return StoolapValue(value_type: STOOLAP_TYPE_BLOB, _padding: 0,
                                v: StoolapValueData(blob: StoolapBlobData(ptr: dest, len: Int64(floats.count * 4))))
        }
    }

    /// Nanoseconds since the Unix epoch, or an error when the date is
    /// outside what an Int64 of nanoseconds can hold (about 1677-2262).
    @inlinable
    static func timestampNanos(_ date: Date) throws -> Int64 {
        guard let nanos = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000_000).rounded()) else {
            throw StoolapError("timestamp \(date) is outside the range a TIMESTAMP can store")
        }
        return nanos
    }

    @inlinable
    @inline(__always)
    static func copyText(_ s: String, arena: inout UnsafeMutableRawPointer) -> StoolapTextData {
        let dest = arena.assumingMemoryBound(to: UInt8.self)
        let len = s.utf8.count
        if len > 0 {
            if s.utf8.withContiguousStorageIfAvailable({ src in
                dest.initialize(from: src.baseAddress!, count: len)
            }) == nil {
                // Bridged string without contiguous UTF-8 storage.
                var i = 0
                for byte in s.utf8 {
                    dest[i] = byte
                    i += 1
                }
            }
        }
        arena += (max(len, 1) + 3) & ~3
        return StoolapTextData(ptr: UnsafeRawPointer(dest).assumingMemoryBound(to: CChar.self), len: Int64(len))
    }
}
