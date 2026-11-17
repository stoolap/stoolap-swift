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

/// Streaming cursor for large result sets.
///
/// Unlike `query()` and `queryRaw()`, `RowCursor` never bulk-materializes
/// the entire result. It reads the underlying `StoolapRows*` in packed
/// chunks (`stoolap_rows_fetch_chunk`) of 32 rows, doubling up to 256,
/// keeping peak memory bounded by one chunk. A runtime error part way
/// through a chunk is thrown before that chunk's earlier rows are seen.
public final class RowCursor {
    private var handle: OpaquePointer?
    private var isPositioned = false

    /// The rows of the current chunk and the index of the current row in
    /// it. Rows are read from the engine in packed chunks of
    /// `chunkSize` rows, which doubles from 32 up to 256.
    private var chunk: ColumnarResult?
    private var rowInChunk = 0
    private var chunkSize: Int32 = 32
    /// Set when a chunk came back short: the engine has no rows left.
    private var exhausted = false

    public let columns: [String]

    public var columnCount: Int {
        columns.count
    }

    public var isClosed: Bool {
        handle == nil
    }

    init(handle: OpaquePointer) {
        self.handle = handle
        columns = CursorRowReader.readColumnNames(handle)
    }

    deinit {
        close()
    }

    /// Advance to the next row.
    ///
    /// Returns `true` when a row is ready, `false` when the cursor is
    /// exhausted. Exhaustion auto-closes the underlying handle.
    public func next() throws -> Bool {
        guard let h = handle else { return false }
        if isPositioned, let chunk = chunk, rowInChunk + 1 < chunk.rowCount {
            rowInChunk += 1
            return true
        }
        isPositioned = false
        chunk = nil
        if exhausted {
            close()
            return false
        }

        var buf: UnsafePointer<UInt8>?
        var len: Int64 = 0
        var count: Int32 = 0
        let requested = chunkSize
        if stoolap_rows_fetch_chunk(h, requested, &buf, &len, &count) != STOOLAP_OK {
            let error = StoolapError.from(rows: h)
            close()
            throw error
        }
        if count == 0 {
            close()
            return false
        }
        let names = columns
        chunk = try BulkRowReader.decodeBorrowed(buf, len) { $0.decodeAsColumnar(cachedColumns: names) }
        exhausted = count < requested
        chunkSize = min(chunkSize * 2, 256)
        rowInChunk = 0
        isPositioned = true
        return true
    }

    /// Materialize the current row.
    public func row() throws -> Row {
        let chunk = try requireCurrentRow()
        return Row(columns: columns, values: chunk[row: rowInChunk])
    }

    /// Read one cell from the current row by index.
    public func value(at index: Int) throws -> Value {
        let chunk = try requireCurrentRow()
        guard index >= 0 && index < columns.count else {
            throw StoolapError("column index \(index) out of range")
        }
        return chunk[row: rowInChunk, column: index]
    }

    /// Read one cell from the current row by column name.
    public func value(named name: String) throws -> Value? {
        for (i, col) in columns.enumerated() where col == name {
            return try value(at: i)
        }
        return nil
    }

    /// Drain the remainder of the cursor with bounded memory usage.
    public func forEachRemaining(_ body: (Row) throws -> Void) throws {
        while try next() {
            try body(row())
        }
    }

    /// Close the cursor early. Safe to call multiple times.
    public func close() {
        isPositioned = false
        chunk = nil
        if let h = handle {
            stoolap_rows_close(h)
            handle = nil
        }
    }

    @inline(__always)
    private func requireCurrentRow() throws -> ColumnarResult {
        guard handle != nil, isPositioned, let chunk = chunk else {
            throw StoolapError("cursor is not positioned on a row")
        }
        return chunk
    }
}
