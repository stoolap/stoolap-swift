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
/// the entire result. It advances one row at a time over the underlying
/// `StoolapRows*`, keeping peak memory bounded by the current row.
public final class RowCursor {
    private var handle: OpaquePointer?
    private var isPositioned = false

    public let columns: [String]

    public var columnCount: Int {
        columns.count
    }

    public var isClosed: Bool {
        handle == nil
    }

    init(handle: OpaquePointer, cachedColumns: [String]? = nil) {
        self.handle = handle
        columns = cachedColumns ?? CursorRowReader.readColumnNames(handle)
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
        let step = stoolap_rows_next(h)
        switch step {
        case STOOLAP_ROW:
            isPositioned = true
            return true
        case STOOLAP_DONE:
            isPositioned = false
            close()
            return false
        default:
            isPositioned = false
            let error = StoolapError.from(rows: h)
            close()
            throw error
        }
    }

    /// Materialize the current row.
    public func row() throws -> Row {
        let h = try requireCurrentRow()
        return CursorRowReader.readCurrentAsRow(h, cachedColumns: columns)
    }

    /// Read one cell from the current row by index.
    public func value(at index: Int) throws -> Value {
        let h = try requireCurrentRow()
        guard index >= 0 && index < columns.count else {
            throw StoolapError("column index \(index) out of range")
        }
        return CursorRowReader.readColumn(h, Int32(index))
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
        if let h = handle {
            stoolap_rows_close(h)
            handle = nil
        }
    }

    @inline(__always)
    private func requireCurrentRow() throws -> OpaquePointer {
        guard let h = handle, isPositioned else {
            throw StoolapError("cursor is not positioned on a row")
        }
        return h
    }
}
