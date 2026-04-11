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

/// A Stoolap transaction.
///
/// Created via `Database.begin()`. Single-threaded ownership only — do
/// not share an instance across threads. Must be either committed or
/// rolled back exactly once; calling either consumes the underlying
/// handle (`stoolap_tx_commit`/`stoolap_tx_rollback` free it on the Rust
/// side regardless of return code).
public final class Transaction {
    /// Set to nil after commit/rollback so subsequent calls fail loudly.
    private var handle: OpaquePointer?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let h = handle {
            // Caller dropped a live transaction. Best-effort rollback;
            // this also frees the StoolapTx on the Rust side.
            _ = stoolap_tx_rollback(h)
        }
    }

    @inline(__always)
    private func requireActive() throws -> OpaquePointer {
        guard let h = handle else {
            throw StoolapError("transaction has already been committed or rolled back")
        }
        return h
    }

    // ---- Execute / Query ----

    @discardableResult
    public func execute(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        let h = try requireActive()
        var affected: Int64 = 0
        let rc = try sql.withCString { sqlPtr -> Int32 in
            try ParameterBinder.withBound(params) { ptr, len in
                stoolap_tx_exec_params(h, sqlPtr, ptr, len, &affected)
            }
        }
        if rc != STOOLAP_OK {
            throw StoolapError.from(tx: h)
        }
        return affected
    }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        let rows = try openCursor(sql: sql, params: params)
        defer { stoolap_rows_close(rows) }
        return try BulkRowReader.drainAsRows(rows)
    }

    public func queryOne(_ sql: String, _ params: [Value] = []) throws -> Row? {
        let rows = try openCursor(sql: sql, params: params)
        defer { stoolap_rows_close(rows) }
        return try CursorRowReader.readFirstAsRow(rows)
    }

    public func queryRaw(_ sql: String, _ params: [Value] = []) throws -> ColumnarResult {
        let rows = try openCursor(sql: sql, params: params)
        defer { stoolap_rows_close(rows) }
        return try BulkRowReader.drainAsColumnar(rows)
    }

    /// Open a streaming cursor over the result set inside this transaction.
    public func queryCursor(_ sql: String, _ params: [Value] = []) throws -> RowCursor {
        let rows = try openCursor(sql: sql, params: params)
        return RowCursor(handle: rows)
    }

    @inline(__always)
    private func openCursor(sql: String, params: [Value]) throws -> OpaquePointer {
        let h = try requireActive()
        var raw: OpaquePointer?
        let rc = try sql.withCString { sqlPtr -> Int32 in
            try ParameterBinder.withBound(params) { ptr, len in
                stoolap_tx_query_params(h, sqlPtr, ptr, len, &raw)
            }
        }
        guard rc == STOOLAP_OK, let raw = raw else {
            throw StoolapError.from(tx: h)
        }
        return raw
    }

    // ---- Commit / Rollback ----

    /// Commit the transaction. Consumes the handle even on failure.
    public func commit() throws {
        guard let h = handle else {
            throw StoolapError("transaction has already been committed or rolled back")
        }
        handle = nil
        let rc = stoolap_tx_commit(h)
        if rc != STOOLAP_OK {
            // Handle is freed; the upstream FFI stashes the error in
            // thread-local storage, accessible via `stoolap_tx_errmsg(nil)`.
            throw Self.consumedTxError(label: "commit")
        }
    }

    /// Roll back the transaction. Consumes the handle even on failure.
    public func rollback() throws {
        guard let h = handle else {
            throw StoolapError("transaction has already been committed or rolled back")
        }
        handle = nil
        let rc = stoolap_tx_rollback(h)
        if rc != STOOLAP_OK {
            throw Self.consumedTxError(label: "rollback")
        }
    }

    /// Read the thread-local error stashed by stoolap_tx_commit /
    /// stoolap_tx_rollback after they consume the handle.
    @usableFromInline
    static func consumedTxError(label: String) -> StoolapError {
        if let cstr = stoolap_tx_errmsg(nil) {
            let msg = String(cString: cstr)
            if !msg.isEmpty {
                return StoolapError(msg)
            }
        }
        return StoolapError("\(label) failed")
    }
}
