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

/// Errors raised by the Stoolap driver.
public struct StoolapError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }

    /// Read the error message attached to a database handle.
    @usableFromInline
    static func from(db: OpaquePointer) -> StoolapError {
        if let cstr = stoolap_errmsg(db) {
            let msg = String(cString: cstr)
            if !msg.isEmpty {
                return StoolapError(msg)
            }
        }
        return StoolapError("unknown database error")
    }

    /// Read the error message attached to a prepared statement handle.
    @usableFromInline
    static func from(stmt: OpaquePointer) -> StoolapError {
        if let cstr = stoolap_stmt_errmsg(stmt) {
            let msg = String(cString: cstr)
            if !msg.isEmpty {
                return StoolapError(msg)
            }
        }
        return StoolapError("unknown statement error")
    }

    /// Read the error message attached to a transaction handle.
    @usableFromInline
    static func from(tx: OpaquePointer) -> StoolapError {
        if let cstr = stoolap_tx_errmsg(tx) {
            let msg = String(cString: cstr)
            if !msg.isEmpty {
                return StoolapError(msg)
            }
        }
        return StoolapError("unknown transaction error")
    }

    /// Read the error message attached to a rows handle.
    @usableFromInline
    static func from(rows: OpaquePointer) -> StoolapError {
        if let cstr = stoolap_rows_errmsg(rows) {
            let msg = String(cString: cstr)
            if !msg.isEmpty {
                return StoolapError(msg)
            }
        }
        return StoolapError("unknown rows error")
    }
}
