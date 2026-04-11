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

/// Prepared statement tests. Mirrors `stoolap-python/tests/test_prepared.py`.
final class PreparedTests: XCTestCase {
    func testPreparedExecute() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let stmt = try db.prepare("INSERT INTO users VALUES ($1, $2)")
        _ = try stmt.execute([.integer(1), .text("Alice")])
        _ = try stmt.execute([.integer(2), .text("Bob")])

        let rows = try db.query("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"]?.stringValue, "Alice")
        XCTAssertEqual(rows[1]["name"]?.stringValue, "Bob")
    }

    func testPreparedQuery() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])

        let stmt = try db.prepare("SELECT * FROM users WHERE id = $1")
        let row1 = try stmt.queryOne([.integer(1)])
        XCTAssertEqual(row1?["name"]?.stringValue, "Alice")

        let row2 = try stmt.queryOne([.integer(2)])
        XCTAssertEqual(row2?["name"]?.stringValue, "Bob")
    }

    func testPreparedQueryReturnsList() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])

        let stmt = try db.prepare("SELECT * FROM users ORDER BY id")
        let rows = try stmt.query()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"]?.stringValue, "Alice")
        XCTAssertEqual(rows[1]["name"]?.stringValue, "Bob")
    }

    func testPreparedQueryRaw() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])

        let stmt = try db.prepare("SELECT id, name FROM users WHERE id = $1")
        let raw = try stmt.queryRaw([.integer(1)])
        XCTAssertEqual(raw.columns, ["id", "name"])
        XCTAssertEqual(raw.rowCount, 1)
        XCTAssertEqual(raw[row: 0, column: 0].int64Value, 1)
        XCTAssertEqual(raw[row: 0, column: 1].stringValue, "Alice")
    }

    func testPreparedExecuteBatch() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let stmt = try db.prepare("INSERT INTO users VALUES ($1, $2)")
        let changes = try stmt.executeBatch([
            [.integer(1), .text("Alice")],
            [.integer(2), .text("Bob")],
            [.integer(3), .text("Charlie")],
        ])
        XCTAssertEqual(changes, 3)

        let rows = try db.query("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 3)
    }

    func testPreparedReuse() throws {
        // Prepared statements reused for many params — verifies the
        // CachedPlanRef path has no per-call state leakage.
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, val TEXT)")

        let insert = try db.prepare("INSERT INTO kv VALUES ($1, $2)")
        let lookup = try db.prepare("SELECT val FROM kv WHERE k = $1")

        for i in 0 ..< 100 {
            _ = try insert.execute([.integer(Int64(i)), .text("value_\(i)")])
        }

        for i in 0 ..< 100 {
            let row = try lookup.queryOne([.integer(Int64(i))])
            XCTAssertNotNil(row)
            XCTAssertEqual(row?["val"]?.stringValue, "value_\(i)")
        }
    }

    func testPreparedQueryOneMissing() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .text("present")])

        let stmt = try db.prepare("SELECT * FROM t WHERE id = $1")
        XCTAssertNotNil(try stmt.queryOne([.integer(1)]))
        XCTAssertNil(try stmt.queryOne([.integer(999)]))
    }

    func testPreparedExecuteError() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])

        // Duplicate PK -> prepared execute should surface a StoolapError.
        let insert = try db.prepare("INSERT INTO t VALUES ($1)")
        XCTAssertThrowsError(try insert.execute([.integer(1)])) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }
}
