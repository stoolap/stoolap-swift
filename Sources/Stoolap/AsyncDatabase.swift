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

/// Async wrapper around `Database`.
///
/// Stoolap's underlying API is synchronous; this wrapper hops calls onto a
/// detached task so they do not block the Swift cooperative thread pool.
/// `Database` itself is `@unchecked Sendable`, so it can be safely captured
/// across the suspension point.
public actor AsyncDatabase {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public static func open(_ path: String = ":memory:") async throws -> AsyncDatabase {
        let db = try await Task.detached(priority: .userInitiated) {
            try Database.open(path)
        }.value
        return AsyncDatabase(db)
    }

    public func execute(_ sql: String, _ params: [Value] = []) async throws -> Int64 {
        let db = self.db
        return try await Task.detached(priority: .userInitiated) {
            try db.execute(sql, params)
        }.value
    }

    public func exec(_ sql: String) async throws {
        let db = self.db
        try await Task.detached(priority: .userInitiated) {
            try db.exec(sql)
        }.value
    }

    public func query(_ sql: String, _ params: [Value] = []) async throws -> [Row] {
        let db = self.db
        return try await Task.detached(priority: .userInitiated) {
            try db.query(sql, params)
        }.value
    }

    public func queryOne(_ sql: String, _ params: [Value] = []) async throws -> Row? {
        let db = self.db
        return try await Task.detached(priority: .userInitiated) {
            try db.queryOne(sql, params)
        }.value
    }

    public func queryRaw(_ sql: String, _ params: [Value] = []) async throws -> ColumnarResult {
        let db = self.db
        return try await Task.detached(priority: .userInitiated) {
            try db.queryRaw(sql, params)
        }.value
    }

    public func prepare(_ sql: String) async throws -> PreparedStatement {
        let db = self.db
        return try await Task.detached(priority: .userInitiated) {
            try db.prepare(sql)
        }.value
    }
}
