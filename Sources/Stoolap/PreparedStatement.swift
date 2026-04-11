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
import os

/// A prepared SQL statement.
///
/// Created via `Database.prepare(_:)`. Holds an opaque `StoolapStmt*` from
/// the upstream `stoolap::ffi` module — the Rust side handles plan caching
/// and column-name interning across repeated calls.
public final class PreparedStatement: @unchecked Sendable {
    @usableFromInline
    let handle: OpaquePointer

    /// Lock protecting `_cachedColumnNames`. The cache is write-once
    /// (nil -> value, never mutated again) so contention is limited to
    /// the very first query call.
    private var _lock = os_unfair_lock()

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        stoolap_stmt_finalize(handle)
    }

    /// Original SQL text.
    public var sql: String {
        if let cstr = stoolap_stmt_sql(handle) {
            return String(cString: cstr)
        }
        return ""
    }

    // ---- Execute ----

    @discardableResult
    public func execute(_ params: [Value] = []) throws -> Int64 {
        var affected: Int64 = 0
        let rc = try ParameterBinder.withBound(params) { ptr, len in
            stoolap_stmt_exec(handle, ptr, len, &affected)
        }
        if rc != STOOLAP_OK {
            throw StoolapError.from(stmt: handle)
        }
        return affected
    }

    // ---- Query ----

    public func query(_ params: [Value] = []) throws -> [Row] {
        let rows = try openCursor(params)
        defer { stoolap_rows_close(rows) }
        let cached = cachedColumnNames
        let result = try BulkRowReader.drainAsRows(rows, cachedColumns: cached)
        if cached == nil, let first = result.first {
            setCachedColumnNames(first.columns)
        }
        return result
    }

    public func queryOne(_ params: [Value] = []) throws -> Row? {
        let rows = try openCursor(params)
        defer { stoolap_rows_close(rows) }
        let cached = cachedColumnNames
        let result = try CursorRowReader.readFirstAsRow(
            rows, cachedColumns: cached
        )
        if cached == nil, let result = result {
            setCachedColumnNames(result.columns)
        }
        return result
    }

    public func queryRaw(_ params: [Value] = []) throws -> ColumnarResult {
        let rows = try openCursor(params)
        defer { stoolap_rows_close(rows) }
        let cached = cachedColumnNames
        let result = try BulkRowReader.drainAsColumnar(rows, cachedColumns: cached)
        if cached == nil, result.rowCount > 0 {
            setCachedColumnNames(result.columns)
        }
        return result
    }

    /// Open a streaming cursor over the result set. Use this for large
    /// reads when you want bounded memory instead of bulk materialization.
    public func queryCursor(_ params: [Value] = []) throws -> RowCursor {
        let rows = try openCursor(params)
        let cached = cachedColumnNames
        let cursor = RowCursor(handle: rows, cachedColumns: cached)
        if cached == nil {
            setCachedColumnNames(cursor.columns)
        }
        return cursor
    }

    @inline(__always)
    private func openCursor(_ params: [Value]) throws -> OpaquePointer {
        var raw: OpaquePointer?
        let rc = try ParameterBinder.withBound(params) { ptr, len in
            stoolap_stmt_query(handle, ptr, len, &raw)
        }
        guard rc == STOOLAP_OK, let raw = raw else {
            throw StoolapError.from(stmt: handle)
        }
        return raw
    }

    // ---- Batch ----

    /// Execute the same prepared statement against multiple parameter sets
    /// inside a single transaction. One FFI call replaces N+2.
    ///
    /// Flattens all parameter sets into a contiguous `StoolapValue` array,
    /// then calls `stoolap_stmt_exec_batch` which begins a transaction,
    /// executes each row with the prepared AST, and commits.
    @discardableResult
    public func executeBatch(_ batch: [[Value]]) throws -> Int64 {
        if batch.isEmpty { return 0 }

        guard let db = ownerDatabase else {
            throw StoolapError("prepared statement is detached from its database")
        }

        let width = batch[0].count
        for (i, row) in batch.enumerated() where row.count != width {
            throw StoolapError(
                "batch rows must all have \(width) parameters; row \(i) has \(row.count)"
            )
        }

        var total: Int64 = 0
        let rc = try BatchParameterBinder.withBoundBatch(batch) { ptr, paramsPerRow, rowCount in
            stoolap_stmt_exec_batch(db.handle, handle, ptr, paramsPerRow, rowCount, &total)
        }
        if rc != STOOLAP_OK {
            throw StoolapError.from(db: db.handle)
        }
        return total
    }

    /// Optional back-reference to the owning Database, set by
    /// `Database.prepare`. Used by `executeBatch` to begin a transaction.
    @usableFromInline
    var ownerDatabase: Database?

    /// Cached column names from the first successful query. For a
    /// prepared statement the column set never changes, so reusing the
    /// same `[String]` avoids N FFI calls + N String allocations on
    /// every subsequent call. COW means all returned Rows/ColumnarResults
    /// share the same backing storage. Protected by `_lock`.
    private var _cachedColumnNames: [String]?

    @inline(__always)
    private var cachedColumnNames: [String]? {
        os_unfair_lock_lock(&_lock)
        let v = _cachedColumnNames
        os_unfair_lock_unlock(&_lock)
        return v
    }

    @inline(__always)
    private func setCachedColumnNames(_ names: [String]) {
        os_unfair_lock_lock(&_lock)
        if _cachedColumnNames == nil {
            _cachedColumnNames = names
        }
        os_unfair_lock_unlock(&_lock)
    }
}
