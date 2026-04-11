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

import Foundation

/// A Stoolap SQL value.
///
/// Mirrors the upstream `stoolap::core::Value` enum at the API surface.
/// At the FFI boundary, values are converted to/from `StoolapValue`
/// (a `#[repr(C)]` tagged union) one at a time using the `value_type`
/// constants from CStoolap.
public enum Value: Equatable, Hashable, Sendable {
    case null
    case integer(Int64)
    case float(Double)
    case text(String)
    case boolean(Bool)
    case timestamp(Date)
    case json(String)
    case blob(Data)
    case vector([Float])

    @inlinable
    public var int64Value: Int64? {
        if case let .integer(v) = self { return v } else { return nil }
    }

    @inlinable
    public var doubleValue: Double? {
        if case let .float(v) = self { return v } else { return nil }
    }

    @inlinable
    public var stringValue: String? {
        switch self {
        case let .text(s), let .json(s): return s
        default: return nil
        }
    }

    @inlinable
    public var boolValue: Bool? {
        if case let .boolean(v) = self { return v } else { return nil }
    }

    @inlinable
    public var dateValue: Date? {
        if case let .timestamp(v) = self { return v } else { return nil }
    }

    @inlinable
    public var isNull: Bool {
        if case .null = self { return true } else { return false }
    }
}

/// Zero-allocation column view into a `ColumnarResult`.
public struct ColumnarColumn: RandomAccessCollection, Sendable, CustomStringConvertible {
    public typealias Element = Value
    public typealias Index = Int

    @usableFromInline
    let cells: [Value]
    @usableFromInline
    let columnIndex: Int
    @usableFromInline
    let rowCount: Int
    @usableFromInline
    let columnCount: Int

    @usableFromInline
    init(cells: [Value], columnIndex: Int, rowCount: Int, columnCount: Int) {
        self.cells = cells
        self.columnIndex = columnIndex
        self.rowCount = rowCount
        self.columnCount = columnCount
    }

    @inlinable
    public var startIndex: Int {
        0
    }

    @inlinable
    public var endIndex: Int {
        rowCount
    }

    @inlinable
    public subscript(position: Int) -> Value {
        precondition(position >= 0 && position < rowCount, "row index out of range")
        return cells[position * columnCount + columnIndex]
    }

    @inlinable
    public func index(after i: Int) -> Int {
        i + 1
    }

    @inlinable
    public func index(before i: Int) -> Int {
        i - 1
    }

    public var description: String {
        Array(self).description
    }
}

/// Columnar query result returned by `queryRaw`.
///
/// Stores all cells in a single flat `[Value]` array in row-major order.
/// Rows stay contiguous for fast drain/decode, while `column(at:)`
/// exposes a zero-allocation strided view for column-wise access.
public struct ColumnarResult: Sendable {
    public let columns: [String]

    /// Flat cell storage in row-major order.
    /// Cell at row r, column c is at index `r * columns.count + c`.
    public let cells: [Value]

    public let rowCount: Int

    @inlinable
    public var columnCount: Int {
        columns.count
    }

    /// Zero-allocation row access.
    @inlinable
    public subscript(row r: Int) -> ArraySlice<Value> {
        precondition(r >= 0 && r < rowCount, "row index out of range")
        let start = r * columns.count
        return cells[start ..< (start + columns.count)]
    }

    /// Access a single cell.
    @inlinable
    public subscript(row r: Int, column c: Int) -> Value {
        precondition(r >= 0 && r < rowCount, "row index out of range")
        precondition(c >= 0 && c < columns.count, "column index out of range")
        return cells[r * columns.count + c]
    }

    /// Zero-allocation view of one entire column.
    @inlinable
    public func column(at index: Int) -> ColumnarColumn {
        precondition(index >= 0 && index < columns.count, "column index out of range")
        return ColumnarColumn(
            cells: cells,
            columnIndex: index,
            rowCount: rowCount,
            columnCount: columns.count
        )
    }

    /// Look up a column by name and return its view.
    @inlinable
    public func column(named name: String) -> ColumnarColumn? {
        for (i, col) in columns.enumerated() where col == name {
            return column(at: i)
        }
        return nil
    }

    @inlinable
    public init(columns: [String], cells: [Value], rowCount: Int) {
        self.columns = columns
        self.cells = cells
        self.rowCount = rowCount
    }
}

/// A single row from `query` / `queryOne` results.
///
/// `Row` is a zero-allocation struct: it wraps an `ArraySlice<Value>`
/// view into a shared result-wide cell storage plus a shared reference
/// to the column names. The whole result allocates ONE big `[Value]`
/// array up front; each `Row` is just a slice into it. This matches
/// (and beats) the C# driver's `object?[]` row layout because there is
/// literally zero heap traffic per row beyond what is needed to hold
/// the cells themselves.
///
/// Lookup-by-name is O(N) over the column count, which is faster than
/// Swift `Dictionary` for the typical 5-15 column counts that most
/// queries return.
public struct Row: Sendable {
    /// Shared across all rows in a single query result, via Swift's
    /// copy-on-write Array semantics. One allocation per result.
    public let columns: [String]

    /// Per-row cell values, in the same order as `columns`. This is an
    /// `ArraySlice` that points into the result-wide cell storage; no
    /// per-row heap allocation is required.
    public let values: ArraySlice<Value>

    @inlinable
    public init(columns: [String], values: ArraySlice<Value>) {
        self.columns = columns
        self.values = values
    }

    /// Look up a cell by column name. Returns `nil` if the name does
    /// not appear in the result. Linear scan; fastest for ≤ ~16 cols.
    @inlinable
    public subscript(_ name: String) -> Value? {
        for (i, col) in columns.enumerated() where col == name {
            return values[values.startIndex + i]
        }
        return nil
    }

    /// Look up a cell by zero-based column index (relative to this row).
    @inlinable
    public subscript(_ index: Int) -> Value {
        values[values.startIndex + index]
    }

    public var count: Int {
        values.count
    }

    /// Iterate columns and values together.
    @inlinable
    public func forEach(_ body: (String, Value) throws -> Void) rethrows {
        let base = values.startIndex
        for i in 0 ..< columns.count {
            try body(columns[i], values[base + i])
        }
    }
}
