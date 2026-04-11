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

// =============================================================================
// Two read paths
// =============================================================================
//
// 1. **Bulk drain (`drainAsDicts`, `drainAsColumnar`)**: calls
//    `stoolap_rows_fetch_all`, which encodes every remaining row into a
//    single binary buffer in Rust. Swift decodes the buffer with
//    `BulkRowDecoder`. Used by `query`/`queryRaw` because per-cell FFI
//    overhead would otherwise dominate large result sets (`SELECT *`).
//
// 2. **Cursor (`drainFirstAsDict`, public `Cursor` API)**: calls
//    `stoolap_rows_next` + `stoolap_rows_column_*` per cell. Used by
//    `queryOne` because it terminates after the first row, and by users
//    who want to skip dict construction entirely.
//
// The bulk path wins for any drain that touches more than ~5 rows because
// FFI dispatch and StoolapRows lifetime tracking add a fixed cost per
// `stoolap_rows_next` step.

// =============================================================================
// Bulk drain via stoolap_rows_fetch_all
// =============================================================================

@usableFromInline
enum BulkRowReader {
    /// Drain `rows` via `stoolap_rows_fetch_all` and decode into the
    /// shape requested by `decode`. The decode closure is non-throwing
    /// because the bulk decoder operates on a trusted buffer with no
    /// bounds checks; only the FFI call itself can fail.
    @inlinable
    static func drain<T>(
        _ rows: OpaquePointer,
        _ decode: (inout BulkRowDecoder) -> T
    ) throws -> T {
        var bufPtr: UnsafeMutablePointer<UInt8>?
        var bufLen: Int64 = 0
        let rc = stoolap_rows_fetch_all(rows, &bufPtr, &bufLen)
        guard rc == STOOLAP_OK, let bufPtr = bufPtr, bufLen >= 0 else {
            throw StoolapError.from(rows: rows)
        }
        defer { stoolap_buffer_free(bufPtr, bufLen) }

        let raw = UnsafeRawBufferPointer(start: bufPtr, count: Int(bufLen))
        var dec = BulkRowDecoder(bytes: raw)
        return decode(&dec)
    }

    /// Drain into `[Row]` — one shared `[Value]` cells allocation, with
    /// each `Row` an `ArraySlice` view. When `cachedColumns` is provided,
    /// skips column-name decoding from the wire buffer.
    @inlinable
    static func drainAsRows(
        _ rows: OpaquePointer,
        cachedColumns: [String]? = nil
    ) throws -> [Row] {
        try drain(rows) { dec in dec.decodeAsRows(cachedColumns: cachedColumns) }
    }

    @inlinable
    static func drainAsColumnar(
        _ rows: OpaquePointer,
        cachedColumns: [String]? = nil
    ) throws -> ColumnarResult {
        try drain(rows) { dec in dec.decodeAsColumnar(cachedColumns: cachedColumns) }
    }
}

/// Wire-format tags emitted by `stoolap_rows_fetch_all`. Stay in sync with
/// `crate stoolap`'s `src/ffi/rows.rs`.
@usableFromInline
enum BulkTag {
    @usableFromInline static let null: UInt8 = 0
    @usableFromInline static let integer: UInt8 = 1
    @usableFromInline static let float: UInt8 = 2
    @usableFromInline static let text: UInt8 = 3
    @usableFromInline static let boolean: UInt8 = 4
    @usableFromInline static let timestamp: UInt8 = 5
    @usableFromInline static let json: UInt8 = 6
    @usableFromInline static let blob: UInt8 = 7 // packed f32 vector payload
}

/// Pure-Swift decoder for the buffer produced by `stoolap_rows_fetch_all`.
///
/// Uses raw pointer arithmetic with **zero bounds checks** on the hot path.
/// The buffer comes from `stoolap::ffi` which we trust to produce a
/// well-formed wire format. A malformed buffer would be an upstream bug.
///
/// Bounds-checking on every byte was costing ~400 μs on the SELECT *
/// full-scan benchmark (70k cell reads × ~5 bytes each × ~1-2 ns per
/// check). Eliminating it was worth the safety tradeoff because the
/// buffer producer is trusted Rust code, not user input.
@usableFromInline
struct BulkRowDecoder {
    /// Raw pointer to the next unread byte.
    @usableFromInline
    var ptr: UnsafePointer<UInt8>

    /// One-past-end pointer (kept only for assertions; not consulted on the
    /// hot path).
    @usableFromInline
    let end: UnsafePointer<UInt8>

    @inlinable
    init(bytes: UnsafeRawBufferPointer) {
        if let base = bytes.baseAddress {
            let b = base.assumingMemoryBound(to: UInt8.self)
            ptr = b
            end = b.advanced(by: bytes.count)
        } else {
            // Empty buffer. Use a static dangling pointer; the decoder
            // will not actually read any bytes in that case.
            let dangling = UnsafePointer<UInt8>(bitPattern: 0x10)!
            ptr = dangling
            end = dangling
        }
    }

    // ---- Primitive readers (unchecked, raw pointer arithmetic) ----

    @inlinable
    @inline(__always)
    mutating func readU8() -> UInt8 {
        let v = ptr.pointee
        ptr = ptr.advanced(by: 1)
        return v
    }

    @inlinable
    @inline(__always)
    mutating func readU16() -> UInt16 {
        let v = UnsafeRawPointer(ptr).loadUnaligned(as: UInt16.self)
        ptr = ptr.advanced(by: 2)
        return UInt16(littleEndian: v)
    }

    @inlinable
    @inline(__always)
    mutating func readU32() -> UInt32 {
        let v = UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self)
        ptr = ptr.advanced(by: 4)
        return UInt32(littleEndian: v)
    }

    @inlinable
    @inline(__always)
    mutating func readI64() -> Int64 {
        let v = UnsafeRawPointer(ptr).loadUnaligned(as: Int64.self)
        ptr = ptr.advanced(by: 8)
        return Int64(littleEndian: v)
    }

    @inlinable
    @inline(__always)
    mutating func readF64() -> Double {
        let bits = UnsafeRawPointer(ptr).loadUnaligned(as: UInt64.self)
        ptr = ptr.advanced(by: 8)
        return Double(bitPattern: UInt64(littleEndian: bits))
    }

    @inlinable
    @inline(__always)
    mutating func readUTF8(length: Int) -> String {
        if length == 0 { return "" }
        let buf = UnsafeBufferPointer(start: ptr, count: length)
        ptr = ptr.advanced(by: length)
        return String(decoding: buf, as: UTF8.self)
    }

    @inlinable
    @inline(__always)
    mutating func readVector(byteLength: Int) -> [Float] {
        let count = byteLength / 4
        var floats = [Float]()
        floats.reserveCapacity(count)
        for i in 0 ..< count {
            let bits = UnsafeRawPointer(ptr.advanced(by: i * 4))
                .loadUnaligned(as: UInt32.self)
            floats.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        ptr = ptr.advanced(by: byteLength)
        return floats
    }

    // ---- Value reader ----

    @inlinable
    @inline(__always)
    mutating func readValue() -> Value {
        let tag = readU8()
        switch tag {
        case BulkTag.null:
            return .null
        case BulkTag.integer:
            return .integer(readI64())
        case BulkTag.float:
            return .float(readF64())
        case BulkTag.text:
            let len = Int(readU32())
            return .text(readUTF8(length: len))
        case BulkTag.boolean:
            return .boolean(readU8() != 0)
        case BulkTag.timestamp:
            let nanos = readI64()
            return .timestamp(Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000))
        case BulkTag.json:
            let len = Int(readU32())
            return .json(readUTF8(length: len))
        case BulkTag.blob:
            let byteLen = Int(readU32())
            return .vector(readVector(byteLength: byteLen))
        default:
            return .null
        }
    }

    // ---- Header readers ----

    @inlinable
    mutating func readColumnNames() -> [String] {
        let colCount = Int(readU32())
        var columns = [String]()
        columns.reserveCapacity(colCount)
        for _ in 0 ..< colCount {
            let len = Int(readU16())
            columns.append(readUTF8(length: len))
        }
        return columns
    }

    /// Advance past the column-name header without allocating Strings.
    /// Used when a cached column list is available.
    @inlinable
    @inline(__always)
    mutating func skipColumnNames() {
        let colCount = Int(readU32())
        for _ in 0 ..< colCount {
            let len = Int(readU16())
            ptr = ptr.advanced(by: len)
        }
    }

    // ---- Result shapes ----

    /// Decode into `[Row]` with **a single allocation for all cells**.
    /// When `cachedColumns` is provided, skips the column-name header
    /// bytes instead of decoding them into fresh Strings.
    @inlinable
    mutating func decodeAsRows(cachedColumns: [String]? = nil) -> [Row] {
        let columns: [String]
        if let cached = cachedColumns {
            skipColumnNames()
            columns = cached
        } else {
            columns = readColumnNames()
        }
        let rowCount = Int(readU32())
        let colCount = columns.count
        let cellCount = rowCount * colCount

        let cells = [Value](unsafeUninitializedCapacity: cellCount) { buf, initialized in
            for i in 0 ..< cellCount {
                buf.initializeElement(at: i, to: readValue())
            }
            initialized = cellCount
        }

        let out = [Row](unsafeUninitializedCapacity: rowCount) { buf, initialized in
            for r in 0 ..< rowCount {
                let start = r * colCount
                let end = start + colCount
                buf.initializeElement(
                    at: r,
                    to: Row(columns: columns, values: cells[start ..< end])
                )
            }
            initialized = rowCount
        }
        return out
    }

    /// Decode into flat `ColumnarResult`.
    /// When `cachedColumns` is provided, skips the column-name header.
    @inlinable
    mutating func decodeAsColumnar(cachedColumns: [String]? = nil) -> ColumnarResult {
        let columns: [String]
        if let cached = cachedColumns {
            skipColumnNames()
            columns = cached
        } else {
            columns = readColumnNames()
        }
        let rowCount = Int(readU32())
        let colCount = columns.count
        let cellCount = rowCount * colCount

        let cells = [Value](unsafeUninitializedCapacity: cellCount) { buf, initialized in
            for i in 0 ..< cellCount {
                buf.initializeElement(at: i, to: readValue())
            }
            initialized = cellCount
        }
        return ColumnarResult(columns: columns, cells: cells, rowCount: rowCount)
    }
}

// =============================================================================
// Cursor accessors via stoolap_rows_next + stoolap_rows_column_*
// =============================================================================

@usableFromInline
enum CursorRowReader {
    /// Read the column at `index` from the current row as a Swift `Value`.
    /// Assumes the cursor has been positioned via `stoolap_rows_next` and
    /// returned `STOOLAP_ROW`.
    @inlinable
    @inline(__always)
    static func readColumn(_ rows: OpaquePointer, _ index: Int32) -> Value {
        let type = stoolap_rows_column_type(rows, index)
        switch type {
        case STOOLAP_TYPE_NULL:
            return .null

        case STOOLAP_TYPE_INTEGER:
            return .integer(stoolap_rows_column_int64(rows, index))

        case STOOLAP_TYPE_FLOAT:
            return .float(stoolap_rows_column_double(rows, index))

        case STOOLAP_TYPE_BOOLEAN:
            return .boolean(stoolap_rows_column_bool(rows, index) != 0)

        case STOOLAP_TYPE_TIMESTAMP:
            let nanos = stoolap_rows_column_timestamp(rows, index)
            return .timestamp(Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000))

        case STOOLAP_TYPE_TEXT:
            var len: Int64 = 0
            guard let cstr = stoolap_rows_column_text(rows, index, &len) else {
                return .null
            }
            return .text(makeString(cstr, len: len))

        case STOOLAP_TYPE_JSON:
            var len: Int64 = 0
            guard let cstr = stoolap_rows_column_text(rows, index, &len) else {
                return .null
            }
            return .json(makeString(cstr, len: len))

        case STOOLAP_TYPE_BLOB:
            var len: Int64 = 0
            guard let bytes = stoolap_rows_column_blob(rows, index, &len) else {
                return .null
            }
            let count = Int(len) / 4
            if count == 0 {
                return .vector([])
            }
            var floats = [Float]()
            floats.reserveCapacity(count)
            for i in 0 ..< count {
                let off = i * 4
                let bits = UInt32(bytes[off])
                    | (UInt32(bytes[off + 1]) << 8)
                    | (UInt32(bytes[off + 2]) << 16)
                    | (UInt32(bytes[off + 3]) << 24)
                floats.append(Float(bitPattern: bits))
            }
            return .vector(floats)

        default:
            return .null
        }
    }

    @inlinable
    @inline(__always)
    static func makeString(_ cstr: UnsafePointer<CChar>, len: Int64) -> String {
        if len <= 0 { return "" }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self),
            count: Int(len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }

    @inlinable
    @inline(__always)
    static func readColumnNames(_ rows: OpaquePointer) -> [String] {
        let n = Int(stoolap_rows_column_count(rows))
        var names = [String]()
        names.reserveCapacity(n)
        for i in 0 ..< n {
            if let cstr = stoolap_rows_column_name(rows, Int32(i)) {
                names.append(String(cString: cstr))
            } else {
                names.append("")
            }
        }
        return names
    }

    /// Read the current row without advancing the cursor.
    @inlinable
    static func readCurrentAsRow(_ rows: OpaquePointer, cachedColumns: [String]) -> Row {
        let n = cachedColumns.count
        let values = [Value](unsafeUninitializedCapacity: n) { buf, initialized in
            for i in 0 ..< n {
                buf.initializeElement(at: i, to: readColumn(rows, Int32(i)))
            }
            initialized = n
        }
        return Row(columns: cachedColumns, values: values[values.startIndex ..< values.endIndex])
    }

    /// Read the first row as a `Row`, ignoring any subsequent rows.
    /// Used by `queryOne`. Returns `nil` if the cursor is empty.
    /// When `cachedColumns` is non-nil, reuses those names instead of
    /// re-reading from the cursor (saves N string allocations per call).
    @inlinable
    static func readFirstAsRow(
        _ rows: OpaquePointer,
        cachedColumns: [String]? = nil
    ) throws -> Row? {
        let step = stoolap_rows_next(rows)
        if step == STOOLAP_DONE { return nil }
        if step != STOOLAP_ROW {
            throw StoolapError.from(rows: rows)
        }
        let names = cachedColumns ?? readColumnNames(rows)
        return readCurrentAsRow(rows, cachedColumns: names)
    }
}
