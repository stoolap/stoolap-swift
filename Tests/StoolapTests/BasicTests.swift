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

/// Basic CRUD operations. Mirrors `stoolap-python/tests/test_basic.py`.
final class BasicTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(Database.version.isEmpty)
    }

    func testOpenMemory() throws {
        let db = try Database.open(":memory:")
        _ = db
    }

    func testOpenEmptyString() throws {
        // Stoolap treats "" the same as ":memory:".
        let db = try Database.open("")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        _ = db
    }

    func testOpenMemoryURL() throws {
        _ = try Database.open("memory://")
    }

    func testOpenDefaults() throws {
        // Database.open() with no args defaults to in-memory.
        _ = try Database.open()
    }

    func testCreateTable() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT)")
        let rows = try db.query("SHOW TABLES")
        let names = rows.compactMap { $0["table_name"]?.stringValue }
        XCTAssertTrue(names.contains("users"))
    }

    func testInsertAndQuery() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")

        try db.execute("INSERT INTO users VALUES ($1, $2, $3)", [.integer(1), .text("Alice"), .integer(30)])
        try db.execute("INSERT INTO users VALUES ($1, $2, $3)", [.integer(2), .text("Bob"), .integer(25)])

        let rows = try db.query("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"]?.int64Value, 1)
        XCTAssertEqual(rows[0]["name"]?.stringValue, "Alice")
        XCTAssertEqual(rows[0]["age"]?.int64Value, 30)
        XCTAssertEqual(rows[1]["id"]?.int64Value, 2)
        XCTAssertEqual(rows[1]["name"]?.stringValue, "Bob")
        XCTAssertEqual(rows[1]["age"]?.int64Value, 25)
    }

    func testQueryOneReturnsNilWhenNoRows() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        let row = try db.queryOne("SELECT * FROM users WHERE id = $1", [.integer(999)])
        XCTAssertNil(row)
    }

    func testQueryRaw() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])

        let raw = try db.queryRaw("SELECT id, name FROM users ORDER BY id")
        XCTAssertEqual(raw.columns, ["id", "name"])
        XCTAssertEqual(raw.rowCount, 2)
        XCTAssertEqual(raw[row: 0, column: 0], .integer(1))
        XCTAssertEqual(raw[row: 0, column: 1], .text("Alice"))
        XCTAssertEqual(raw[row: 1, column: 0], .integer(2))
        XCTAssertEqual(raw[row: 1, column: 1], .text("Bob"))
        XCTAssertEqual(Array(raw.column(at: 0)), [.integer(1), .integer(2)])
        XCTAssertEqual(try Array(XCTUnwrap(raw.column(named: "name"))), [.text("Alice"), .text("Bob")])
    }

    func testQueryCursor() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])

        let cursor = try db.queryCursor("SELECT id, name FROM users ORDER BY id")
        XCTAssertEqual(cursor.columns, ["id", "name"])

        XCTAssertTrue(try cursor.next())
        XCTAssertEqual(try cursor.value(at: 0), .integer(1))
        XCTAssertEqual(try cursor.value(named: "name"), .text("Alice"))

        XCTAssertTrue(try cursor.next())
        let row = try cursor.row()
        XCTAssertEqual(row["id"], .integer(2))
        XCTAssertEqual(row["name"], .text("Bob"))

        XCTAssertFalse(try cursor.next())
    }

    func testUpdate() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])

        let changes = try db.execute("UPDATE users SET name = $1 WHERE id = $2", [.text("Alicia"), .integer(1)])
        XCTAssertEqual(changes, 1)

        let row = try db.queryOne("SELECT name FROM users WHERE id = $1", [.integer(1)])
        XCTAssertEqual(row?["name"]?.stringValue, "Alicia")
    }

    func testDelete() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])

        let changes = try db.execute("DELETE FROM users WHERE id = $1", [.integer(1)])
        XCTAssertEqual(changes, 1)

        let rows = try db.query("SELECT * FROM users")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"]?.int64Value, 2)
    }

    func testExecMultipleStatements() throws {
        let db = try Database.open(":memory:")
        try db.exec("""
            CREATE TABLE a (id INTEGER PRIMARY KEY);
            CREATE TABLE b (id INTEGER PRIMARY KEY);
        """)
        let rows = try db.query("SHOW TABLES")
        let names = Set(rows.compactMap { $0["table_name"]?.stringValue })
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
    }

    func testExecIgnoresEmptyStatementsAndComments() throws {
        let db = try Database.open(":memory:")
        // Exercise the statement splitter: line comments, block comments,
        // trailing semicolons, blank lines.
        try db.exec("""
            -- create the first table
            CREATE TABLE a (id INTEGER PRIMARY KEY);

            /* block comment; with; semicolons inside */
            CREATE TABLE b (id INTEGER PRIMARY KEY);
            ;
        """)
        let rows = try db.query("SHOW TABLES")
        let names = Set(rows.compactMap { $0["table_name"]?.stringValue })
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
    }

    func testExecHandlesQuotedSemicolons() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
        // A quoted semicolon should not split the statement.
        try db.exec("INSERT INTO t VALUES (1, 'a; b; c');")
        let row = try db.queryOne("SELECT val FROM t WHERE id = 1")
        XCTAssertEqual(row?["val"]?.stringValue, "a; b; c")
    }

    func testErrorHandling() throws {
        let db = try Database.open(":memory:")
        XCTAssertThrowsError(try db.execute("SELECTX * FROM nonexistent")) { err in
            XCTAssertTrue(err is StoolapError)
            if let stoolapErr = err as? StoolapError {
                XCTAssertFalse(stoolapErr.message.isEmpty)
                // StoolapError.description should match message
                XCTAssertEqual(stoolapErr.description, stoolapErr.message)
            }
        }
    }
}
