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

/// Transaction tests. Mirrors `stoolap-python/tests/test_transactions.py`.
final class TransactionTests: XCTestCase {
    func testCommit() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let tx = try db.begin()
        try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])
        try tx.commit()

        let rows = try db.query("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
    }

    func testRollback() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let tx = try db.begin()
        try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
        try tx.rollback()

        let rows = try db.query("SELECT * FROM users")
        XCTAssertEqual(rows.count, 0)
    }

    func testWithTransactionCommit() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let returned = try db.withTransaction { tx in
            try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
            try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])
            return "done"
        }
        XCTAssertEqual(returned, "done")

        let rows = try db.query("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
    }

    func testWithTransactionRollbackOnThrow() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        struct Boom: Error {}
        XCTAssertThrowsError(try db.withTransaction { tx in
            try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
            throw Boom()
        }) { err in
            XCTAssertTrue(err is Boom)
        }

        let rows = try db.query("SELECT * FROM users")
        XCTAssertEqual(rows.count, 0)
    }

    func testTxSeesOwnUncommittedWrites() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let tx = try db.begin()
        try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])

        let rows = try tx.query("SELECT * FROM users")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"]?.stringValue, "Alice")

        let one = try tx.queryOne("SELECT name FROM users WHERE id = $1", [.integer(1)])
        XCTAssertEqual(one?["name"]?.stringValue, "Alice")

        let raw = try tx.queryRaw("SELECT id, name FROM users")
        XCTAssertEqual(raw.columns, ["id", "name"])
        XCTAssertEqual(raw.rowCount, 1)
        XCTAssertEqual(raw[row: 0, column: 1].stringValue, "Alice")

        try tx.commit()
    }

    func testTxDeinitRollsBack() throws {
        // A Transaction dropped without commit/rollback should roll back
        // automatically via deinit (best-effort).
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        do {
            let tx = try db.begin()
            try tx.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
            // tx goes out of scope here with no explicit commit/rollback
        }

        let rows = try db.query("SELECT * FROM users")
        XCTAssertEqual(rows.count, 0)
    }

    func testAutoCommitCommitsImmediately() throws {
        // A plain `db.execute` without an open tx should be visible
        // immediately to subsequent queries.
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        let row = try db.queryOne("SELECT COUNT(*) AS n FROM t")
        XCTAssertEqual(row?["n"]?.int64Value, 1)
    }
}
