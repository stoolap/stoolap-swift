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

/// A prepared SQL statement.
///
/// Created via `Database.prepare(_:)`. Holds an opaque `StoolapStmt*` from
/// the upstream `stoolap::ffi` module — the Rust side handles plan caching
/// and column-name interning across repeated calls.
public final class PreparedStatement: @unchecked Sendable {
    @usableFromInline
    let handle: OpaquePointer

    /// Serializes calls on `handle` (which keeps the last error) and
    /// guards `_cachedColumnNames`.
    private let lock = HandleLock()

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
        try ParameterBinder.withBound(params) { ptr, len in
            try lock.withLock {
                var affected: Int64 = 0
                if stoolap_stmt_exec(handle, ptr, len, &affected) != STOOLAP_OK {
                    throw StoolapError.from(stmt: handle)
                }
                return affected
            }
        }
    }

    // ---- Query ----

    public func query(_ params: [Value] = []) throws -> [Row] {
        let rows = try openCursor(params)
        defer { stoolap_rows_close(rows) }
        let cached = cachedColumnNames
        let result = try BulkRowReader.drainAsRows(rows, cachedColumns: cached)
        if let first = result.first, first.columns != cached {
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
        if let result = result, result.columns != cached {
            setCachedColumnNames(result.columns)
        }
        return result
    }

    public func queryRaw(_ params: [Value] = []) throws -> ColumnarResult {
        let rows = try openCursor(params)
        defer { stoolap_rows_close(rows) }
        let cached = cachedColumnNames
        let result = try BulkRowReader.drainAsColumnar(rows, cachedColumns: cached)
        if result.columns != cached {
            setCachedColumnNames(result.columns)
        }
        return result
    }

    /// Open a streaming cursor over the result set. Use this for large
    /// reads when you want bounded memory instead of bulk materialization.
    public func queryCursor(_ params: [Value] = []) throws -> RowCursor {
        RowCursor(handle: try openCursor(params))
    }

    @inline(__always)
    private func openCursor(_ params: [Value]) throws -> OpaquePointer {
        try ParameterBinder.withBound(params) { ptr, len in
            try lock.withLock {
                var raw: OpaquePointer?
                let rc = stoolap_stmt_query(handle, ptr, len, &raw)
                guard rc == STOOLAP_OK, let raw = raw else {
                    throw StoolapError.from(stmt: handle)
                }
                return raw
            }
        }
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

        return try BatchParameterBinder.withBoundBatch(batch) { ptr, paramsPerRow, rowCount in
            // Lock order: database, then statement.
            try db.lock.withLock {
                try lock.withLock {
                    var total: Int64 = 0
                    let rc = stoolap_stmt_exec_batch(
                        db.handle, handle, ptr, paramsPerRow, rowCount, &total
                    )
                    if rc != STOOLAP_OK {
                        throw StoolapError.from(db: db.handle)
                    }
                    return total
                }
            }
        }
    }

    /// Optional back-reference to the owning Database, set by
    /// `Database.prepare`. Used by `executeBatch` to begin a transaction.
    @usableFromInline
    var ownerDatabase: Database?

    /// Column names of the latest result. Each result's columns are
    /// compared against them, and a match reuses the same `[String]`
    /// instead of allocating N Strings; a mismatch (the schema changed
    /// after the prepare) replaces them. COW means all returned
    /// Rows/ColumnarResults share the same backing storage. Protected by
    /// `lock`.
    private var _cachedColumnNames: [String]?

    @inline(__always)
    private var cachedColumnNames: [String]? {
        lock.withLock { _cachedColumnNames }
    }

    @inline(__always)
    private func setCachedColumnNames(_ names: [String]) {
        lock.withLock { _cachedColumnNames = names }
    }
}
