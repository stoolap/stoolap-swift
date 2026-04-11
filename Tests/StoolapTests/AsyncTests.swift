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

@testable import Stoolap
import XCTest

/// Async API tests. Mirrors `stoolap-python/tests/test_async.py`.
final class AsyncTests: XCTestCase {
    func testAsyncOpenAndQuery() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        try await db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        let n = try await db.execute("INSERT INTO users VALUES ($1, $2)",
                                     [.integer(1), .text("Alice")])
        XCTAssertEqual(n, 1)

        let rows = try await db.query("SELECT * FROM users")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"]?.stringValue, "Alice")
    }

    func testAsyncQueryOne() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        try await db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await db.execute("INSERT INTO users VALUES ($1, $2)",
                                 [.integer(1), .text("Alice")])

        let row = try await db.queryOne("SELECT * FROM users WHERE id = $1", [.integer(1)])
        XCTAssertEqual(row?["name"]?.stringValue, "Alice")

        let none = try await db.queryOne("SELECT * FROM users WHERE id = $1", [.integer(999)])
        XCTAssertNil(none)
    }

    func testAsyncQueryRaw() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        try await db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await db.execute("INSERT INTO users VALUES ($1, $2)",
                                 [.integer(1), .text("Alice")])

        let raw = try await db.queryRaw("SELECT id, name FROM users")
        XCTAssertEqual(raw.columns, ["id", "name"])
        XCTAssertEqual(raw.rowCount, 1)
        XCTAssertEqual(raw[row: 0, column: 0].int64Value, 1)
        XCTAssertEqual(raw[row: 0, column: 1].stringValue, "Alice")
    }

    func testAsyncPreparedStatement() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        try await db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let insert = try await db.prepare("INSERT INTO users VALUES ($1, $2)")
        _ = try insert.execute([.integer(1), .text("Alice")])
        _ = try insert.execute([.integer(2), .text("Bob")])

        let lookup = try await db.prepare("SELECT * FROM users WHERE id = $1")
        let row = try lookup.queryOne([.integer(1)])
        XCTAssertEqual(row?["name"]?.stringValue, "Alice")
    }

    func testAsyncErrorHandling() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        do {
            _ = try await db.query("SELECT * FROM nonexistent")
            XCTFail("expected StoolapError")
        } catch is StoolapError {
            // ok
        }
    }

    func testAsyncExecMultiStatement() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        try await db.exec("""
            CREATE TABLE a (id INTEGER PRIMARY KEY);
            CREATE TABLE b (id INTEGER PRIMARY KEY);
        """)
        let rows = try await db.query("SHOW TABLES")
        let names = Set(rows.compactMap { $0["table_name"]?.stringValue })
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
    }

    func testAsyncExecuteFailure() async throws {
        let db = try await AsyncDatabase.open(":memory:")
        try await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        _ = try await db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        do {
            _ = try await db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
            XCTFail("expected duplicate key error")
        } catch is StoolapError {
            // ok
        }
    }
}
