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

/// A Stoolap database connection.
///
/// `Database` wraps an opaque `StoolapDB*` handle from the upstream
/// `stoolap::ffi` module. It is safe to share across threads (the
/// underlying type uses interior locking), but `Transaction` instances
/// returned from `begin()` must be used by at most one thread at a time.
public final class Database: @unchecked Sendable {
    @usableFromInline
    let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    /// Open a database.
    ///
    /// Accepts:
    /// - `:memory:` or empty string for an in-memory database
    /// - `memory://` for an in-memory database
    /// - `file:///path/to/db` or a raw filesystem path for a file-backed database
    public static func open(_ path: String = ":memory:") throws -> Database {
        let dsn = translateDSN(path)
        var raw: OpaquePointer?
        let rc = dsn.withCString { stoolap_open($0, &raw) }
        guard rc == STOOLAP_OK, let raw = raw else {
            // Without a valid handle we can't use stoolap_errmsg directly,
            // but the upstream ffi stashes the message in thread-local
            // storage, accessible via stoolap_errmsg(nil).
            if let cstr = stoolap_errmsg(nil) {
                let msg = String(cString: cstr)
                if !msg.isEmpty {
                    throw StoolapError(msg)
                }
            }
            throw StoolapError("failed to open database: \(dsn)")
        }
        return Database(handle: raw)
    }

    deinit {
        _ = stoolap_close(handle)
    }

    /// Returns the underlying Rust crate version (e.g. "0.4.0").
    public static var version: String {
        if let cstr = stoolap_version() {
            return String(cString: cstr)
        }
        return ""
    }

    private static func translateDSN(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == ":memory:" {
            return "memory://"
        }
        if trimmed.hasPrefix("memory://") || trimmed.hasPrefix("file://") {
            return trimmed
        }
        return "file://\(trimmed)"
    }

    // ---- Execute ----

    /// Execute a single DDL/DML statement. Returns rows affected.
    @discardableResult
    public func execute(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        var affected: Int64 = 0
        let rc = try sql.withCString { sqlPtr -> Int32 in
            try ParameterBinder.withBound(params) { ptr, len in
                stoolap_exec_params(handle, sqlPtr, ptr, len, &affected)
            }
        }
        if rc != STOOLAP_OK {
            throw StoolapError.from(db: handle)
        }
        return affected
    }

    /// Execute one or more semicolon-separated DDL/DML statements with no
    /// parameters. Useful for schema setup.
    public func exec(_ sql: String) throws {
        for stmt in Self.splitStatements(sql) {
            let trimmed = stmt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            _ = try execute(trimmed)
        }
    }

    // ---- Query ----

    /// Run a query and return all rows as a `[Row]` array. Each `Row`
    /// supports both `row["column_name"]` and `row[index]` access.
    /// Bulk-drains via `stoolap_rows_fetch_all` for one-FFI-call efficiency.
    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        let rows = try openCursor(sql: sql, params: params)
        defer { stoolap_rows_close(rows) }
        return try BulkRowReader.drainAsRows(rows)
    }

    /// Run a query and return the first row, or nil if there are none.
    /// Uses cursor accessors directly — no encode/decode round-trip.
    public func queryOne(_ sql: String, _ params: [Value] = []) throws -> Row? {
        let rows = try openCursor(sql: sql, params: params)
        defer { stoolap_rows_close(rows) }
        return try CursorRowReader.readFirstAsRow(rows)
    }

    /// Run a query and return rows in a flat raw form. Rows stay
    /// contiguous for decode speed, and `ColumnarResult.column(at:)`
    /// exposes zero-allocation column views when you want column-wise
    /// access.
    public func queryRaw(_ sql: String, _ params: [Value] = []) throws -> ColumnarResult {
        let rows = try openCursor(sql: sql, params: params)
        defer { stoolap_rows_close(rows) }
        return try BulkRowReader.drainAsColumnar(rows)
    }

    /// Open a streaming cursor over the result set. Prefer this for very
    /// large reads when you do not want `query()` / `queryRaw()` to
    /// materialize every row up front.
    public func queryCursor(_ sql: String, _ params: [Value] = []) throws -> RowCursor {
        let rows = try openCursor(sql: sql, params: params)
        return RowCursor(handle: rows)
    }

    @inline(__always)
    private func openCursor(sql: String, params: [Value]) throws -> OpaquePointer {
        var raw: OpaquePointer?
        let rc = try sql.withCString { sqlPtr -> Int32 in
            try ParameterBinder.withBound(params) { ptr, len in
                stoolap_query_params(handle, sqlPtr, ptr, len, &raw)
            }
        }
        guard rc == STOOLAP_OK, let raw = raw else {
            throw StoolapError.from(db: handle)
        }
        return raw
    }

    // ---- Transactions ----

    /// Begin a transaction.
    public func begin() throws -> Transaction {
        var raw: OpaquePointer?
        let rc = stoolap_begin(handle, &raw)
        guard rc == STOOLAP_OK, let raw = raw else {
            throw StoolapError.from(db: handle)
        }
        return Transaction(handle: raw)
    }

    /// Run a closure inside a transaction. Auto-commits on success,
    /// auto-rolls back on thrown error.
    public func withTransaction<T>(_ body: (Transaction) throws -> T) throws -> T {
        let tx = try begin()
        do {
            let result = try body(tx)
            try tx.commit()
            return result
        } catch {
            try? tx.rollback()
            throw error
        }
    }

    // ---- Prepared statements ----

    /// Parse a SQL statement once and reuse the cached plan.
    public func prepare(_ sql: String) throws -> PreparedStatement {
        var raw: OpaquePointer?
        let rc = sql.withCString { stoolap_prepare(handle, $0, &raw) }
        guard rc == STOOLAP_OK, let raw = raw else {
            throw StoolapError.from(db: handle)
        }
        let stmt = PreparedStatement(handle: raw)
        // Hold a strong back-reference so executeBatch can begin a tx on
        // this database. The Database itself is `@unchecked Sendable` and
        // is safe to share.
        stmt.ownerDatabase = self
        return stmt
    }

    // ---- Helpers ----

    /// Pure-Swift SQL splitter. Handles single/double quoted strings,
    /// `--` line comments, and `/* */` block comments. Used by `exec()`
    /// so users can pass multi-statement schema scripts in a single call.
    @usableFromInline
    static func splitStatements(_ input: String) -> [String] {
        var result = [String]()
        var current = ""
        var inSingle = false
        var inDouble = false
        var inLineComment = false
        var inBlockComment = false

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if inLineComment {
                if c == "\n" {
                    inLineComment = false
                    current.append(c)
                }
                i += 1
                continue
            }

            if !inSingle, !inDouble, !inBlockComment, c == "-",
               i + 1 < chars.count, chars[i + 1] == "-"
            {
                inLineComment = true
                i += 2
                continue
            }

            if inBlockComment {
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if !inSingle, !inDouble, c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                inBlockComment = true
                i += 2
                continue
            }

            if !inBlockComment, !inLineComment {
                if c == "'", i == 0 || chars[i - 1] != "\\" {
                    inSingle.toggle()
                } else if c == "\"", i == 0 || chars[i - 1] != "\\" {
                    inDouble.toggle()
                }
            }

            if c == ";", !inSingle, !inDouble, !inBlockComment, !inLineComment {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
