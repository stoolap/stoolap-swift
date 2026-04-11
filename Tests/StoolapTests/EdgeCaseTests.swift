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

/// Edge cases and error handling. Mirrors `stoolap-python/tests/test_edge_cases.py`.
final class EdgeCaseTests: XCTestCase {
    // MARK: - Error handling

    func testInvalidSQL() throws {
        let db = try Database.open(":memory:")
        XCTAssertThrowsError(try db.execute("SELECTX * FROM foo")) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testTableNotFound() throws {
        let db = try Database.open(":memory:")
        XCTAssertThrowsError(try db.query("SELECT * FROM nonexistent")) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testDuplicatePrimaryKey() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testConstraintNotNull() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .null])) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    // MARK: - Empty results

    func testQueryEmptyTable() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let rows = try db.query("SELECT * FROM t")
        XCTAssertEqual(rows.count, 0)
    }

    func testQueryRawEmpty() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        let raw = try db.queryRaw("SELECT * FROM t")
        XCTAssertEqual(raw.columns, ["id", "name"])
        XCTAssertEqual(raw.rowCount, 0)
    }

    func testQueryOneEmpty() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let row = try db.queryOne("SELECT * FROM t WHERE id = $1", [.integer(999)])
        XCTAssertNil(row)
    }

    // MARK: - No params

    func testExecuteNoParams() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY DEFAULT 1, val TEXT DEFAULT 'hi')")
        try db.execute("INSERT INTO t (id) VALUES (1)")
        let row = try db.queryOne("SELECT * FROM t")
        XCTAssertEqual(row?["val"]?.stringValue, "hi")
    }

    func testQueryNoParams() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try db.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        let rows = try db.query("SELECT * FROM t")
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Transaction edge cases

    func testTxUseAfterCommit() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        let tx = try db.begin()
        try tx.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        try tx.commit()

        XCTAssertThrowsError(try tx.execute("INSERT INTO t VALUES ($1)", [.integer(2)])) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testTxUseAfterRollback() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        let tx = try db.begin()
        try tx.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        try tx.rollback()

        XCTAssertThrowsError(try tx.execute("INSERT INTO t VALUES ($1)", [.integer(2)])) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testTxDoubleCommit() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        let tx = try db.begin()
        try tx.execute("INSERT INTO t VALUES ($1)", [.integer(1)])
        try tx.commit()

        XCTAssertThrowsError(try tx.commit()) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testTxDoubleRollback() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        let tx = try db.begin()
        try tx.rollback()

        XCTAssertThrowsError(try tx.rollback()) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testTxQueryAfterCommit() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        let tx = try db.begin()
        try tx.commit()

        XCTAssertThrowsError(try tx.query("SELECT * FROM t")) { err in
            XCTAssertTrue(err is StoolapError)
        }
        XCTAssertThrowsError(try tx.queryOne("SELECT * FROM t")) { err in
            XCTAssertTrue(err is StoolapError)
        }
        XCTAssertThrowsError(try tx.queryRaw("SELECT * FROM t")) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    // MARK: - Batch edge cases

    func testExecuteBatchEmpty() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let stmt = try db.prepare("INSERT INTO t VALUES ($1)")
        let changes = try stmt.executeBatch([])
        XCTAssertEqual(changes, 0)
    }

    func testExecuteBatchSingle() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let stmt = try db.prepare("INSERT INTO t VALUES ($1)")
        let changes = try stmt.executeBatch([[.integer(1)]])
        XCTAssertEqual(changes, 1)
    }

    func testExecuteBatchInconsistentWidthThrows() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (a INTEGER, b INTEGER)")
        let stmt = try db.prepare("INSERT INTO t VALUES ($1, $2)")
        XCTAssertThrowsError(try stmt.executeBatch([
            [.integer(1), .integer(2)],
            [.integer(3)], // bad row: 1 value instead of 2
        ])) { err in
            XCTAssertTrue(err is StoolapError)
        }
    }

    func testExecuteBatchManyRows() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
        let stmt = try db.prepare("INSERT INTO t VALUES ($1, $2)")

        var batch = [[Value]]()
        batch.reserveCapacity(1000)
        for i in 0 ..< 1000 {
            batch.append([.integer(Int64(i)), .text("val_\(i)")])
        }
        let changes = try stmt.executeBatch(batch)
        XCTAssertEqual(changes, 1000)

        let count = try db.queryOne("SELECT COUNT(*) AS n FROM t")
        XCTAssertEqual(count?["n"]?.int64Value, 1000)
    }

    // MARK: - Prepared statement edge cases

    func testPreparedMultipleQueries() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

        let insert = try db.prepare("INSERT INTO t VALUES ($1, $2)")
        _ = try insert.executeBatch([
            [.integer(1), .text("Alice")],
            [.integer(2), .text("Bob")],
            [.integer(3), .text("Charlie")],
        ])

        let lookup = try db.prepare("SELECT name FROM t WHERE id = $1")
        XCTAssertEqual(try lookup.queryOne([.integer(1)])?["name"]?.stringValue, "Alice")
        XCTAssertEqual(try lookup.queryOne([.integer(2)])?["name"]?.stringValue, "Bob")
        XCTAssertEqual(try lookup.queryOne([.integer(3)])?["name"]?.stringValue, "Charlie")
        XCTAssertNil(try lookup.queryOne([.integer(999)]))
    }

    // MARK: - SHOW TABLES

    func testShowTables() throws {
        let db = try Database.open(":memory:")
        try db.exec("""
            CREATE TABLE alpha (id INTEGER PRIMARY KEY);
            CREATE TABLE beta (id INTEGER PRIMARY KEY);
            CREATE TABLE gamma (id INTEGER PRIMARY KEY);
        """)
        let rows = try db.query("SHOW TABLES")
        let names = Set(rows.compactMap { $0["table_name"]?.stringValue })
        XCTAssertTrue(names.isSuperset(of: ["alpha", "beta", "gamma"]))
    }

    // MARK: - Large data

    func testLargeText() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
        let large = String(repeating: "x", count: 100_000)
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .text(large)])
        let row = try db.queryOne("SELECT val FROM t WHERE id = $1", [.integer(1)])
        XCTAssertEqual(row?["val"]?.stringValue?.count, 100_000)
        XCTAssertEqual(row?["val"]?.stringValue, large)
    }

    func testManyColumns() throws {
        let db = try Database.open(":memory:")
        let cols = (0 ..< 50).map { "c\($0) INTEGER" }.joined(separator: ", ")
        try db.exec("CREATE TABLE wide (id INTEGER PRIMARY KEY, \(cols))")

        let placeholders = (1 ... 51).map { "$\($0)" }.joined(separator: ", ")
        let params = (0 ..< 51).map { Value.integer(Int64($0)) }
        try db.execute("INSERT INTO wide VALUES (\(placeholders))", params)

        let row = try db.queryOne("SELECT * FROM wide WHERE id = $1", [.integer(0)])
        XCTAssertEqual(row?["c0"]?.int64Value, 1)
        XCTAssertEqual(row?["c49"]?.int64Value, 50)
    }

    func testManyRowsRoundtrip() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val INTEGER)")
        let insert = try db.prepare("INSERT INTO t VALUES ($1, $2)")
        let n = 5000
        var batch = [[Value]]()
        batch.reserveCapacity(n)
        for i in 0 ..< n {
            batch.append([.integer(Int64(i)), .integer(Int64(i * 2))])
        }
        let inserted = try insert.executeBatch(batch)
        XCTAssertEqual(inserted, Int64(n))

        let result = try db.queryRaw("SELECT id, val FROM t ORDER BY id")
        XCTAssertEqual(result.rowCount, n)
        XCTAssertEqual(result[row: 0, column: 0].int64Value, 0)
        XCTAssertEqual(result[row: n - 1, column: 1].int64Value, Int64((n - 1) * 2))
    }
}
