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

/// Chunked cursors, the prepared statement column cache, shared handles
/// across threads, and engine 0.5.0 parameter rules.
final class DriverPathTests: XCTestCase {
    private func makeDB(rows: Int) throws -> Database {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        if rows > 0 {
            let batch: [[Value]] = (1 ... rows).map { [.integer(Int64($0)), .text("n\($0)")] }
            try db.prepare("INSERT INTO t VALUES ($1, $2)").executeBatch(batch)
        }
        return db
    }

    /// Row counts around the chunk sizes (32, then doubling to 256).
    func testCursorAcrossChunkBoundaries() throws {
        for count in [0, 1, 31, 32, 33, 96, 97, 1000] {
            let db = try makeDB(rows: count)
            let cursor = try db.queryCursor("SELECT id, name FROM t ORDER BY id")
            XCTAssertEqual(cursor.columns, ["id", "name"])
            var seen = 0
            while try cursor.next() {
                seen += 1
                XCTAssertEqual(try cursor.value(at: 0), .integer(Int64(seen)))
                XCTAssertEqual(try cursor.value(named: "name"), .text("n\(seen)"))
                XCTAssertEqual(try cursor.row()["id"], .integer(Int64(seen)))
            }
            XCTAssertEqual(seen, count, "rows read for \(count)")
            XCTAssertTrue(cursor.isClosed)
            XCTAssertFalse(try cursor.next())
            XCTAssertThrowsError(try cursor.row())
        }
    }

    func testCursorCloseMidChunk() throws {
        let db = try makeDB(rows: 100)
        let cursor = try db.queryCursor("SELECT id FROM t ORDER BY id")
        XCTAssertTrue(try cursor.next())
        XCTAssertTrue(try cursor.next())
        cursor.close()
        XCTAssertTrue(cursor.isClosed)
        XCTAssertFalse(try cursor.next())
        XCTAssertThrowsError(try cursor.value(at: 0))
    }

    func testCursorValueIndexOutOfRange() throws {
        let db = try makeDB(rows: 1)
        let cursor = try db.queryCursor("SELECT id FROM t")
        XCTAssertTrue(try cursor.next())
        XCTAssertThrowsError(try cursor.value(at: 1))
        XCTAssertThrowsError(try cursor.value(at: -1))
    }

    /// A prepared statement caches its column names; a schema change
    /// after the prepare must not reuse the stale list.
    func testPreparedColumnsFollowSchemaChange() throws {
        let db = try makeDB(rows: 2)
        let stmt = try db.prepare("SELECT * FROM t ORDER BY id")
        XCTAssertEqual(try stmt.query()[0].columns, ["id", "name"])
        XCTAssertEqual(try stmt.queryOne()?.columns, ["id", "name"])

        try db.execute("ALTER TABLE t ADD COLUMN extra INTEGER")
        try db.execute("UPDATE t SET extra = id * 10")
        let expected = try db.query("SELECT * FROM t ORDER BY id")

        let rows = try stmt.query()
        XCTAssertEqual(rows[0].columns, expected[0].columns)
        XCTAssertEqual(rows.map { Array($0.values) }, expected.map { Array($0.values) })

        let one = try stmt.queryOne()
        XCTAssertEqual(one?.columns, expected[0].columns)
        XCTAssertEqual(one.map { Array($0.values) }, Array(expected[0].values))

        let raw = try stmt.queryRaw()
        XCTAssertEqual(raw.columns, expected[0].columns)
        XCTAssertEqual(raw.cells.count, expected.count * expected[0].columns.count)
    }

    /// Many threads sharing one Database and one PreparedStatement: every
    /// result and every error message must belong to its own call.
    func testSharedHandlesAcrossThreads() throws {
        let db = try makeDB(rows: 500)
        let stmt = try db.prepare("SELECT name FROM t WHERE id = $1")
        let failures = Failures()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0 ..< 300 {
                let id = Int64((worker * 300 + i) % 500 + 1)
                do {
                    if try stmt.queryOne([.integer(id)])?["name"] != .text("n\(id)") {
                        failures.add("prepared queryOne \(id)")
                    }
                    if try db.query("SELECT name FROM t WHERE id = $1", [.integer(id)]).first?["name"]
                        != .text("n\(id)")
                    {
                        failures.add("query \(id)")
                    }
                    try db.execute("UPDATE t SET name = $1 WHERE id = $2", [.text("n\(id)"), .integer(id)])
                } catch {
                    failures.add("unexpected error: \(error)")
                }
                do {
                    _ = try db.query("SELECT * FROM missing_table_\(worker)")
                    failures.add("missing table query did not fail")
                } catch let error as StoolapError {
                    if !error.message.contains("missing_table_\(worker)") {
                        failures.add("error from another call: \(error.message)")
                    }
                } catch {
                    failures.add("unexpected error type: \(error)")
                }
            }
        }
        XCTAssertEqual(failures.all, [])
    }

    /// Since engine 0.5.0 a parameter without a value is an error rather
    /// than NULL.
    func testMissingParameterIsAnError() throws {
        let db = try makeDB(rows: 1)
        XCTAssertThrowsError(try db.query("SELECT * FROM t WHERE id = $1 AND name = $2", [.integer(1)]))
        let stmt = try db.prepare("SELECT * FROM t WHERE id = $1")
        XCTAssertThrowsError(try stmt.query())
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Parameter binding and `exec()` scripts.
final class BindingAndScriptTests: XCTestCase {
    /// A Date whose nanoseconds do not fit an Int64 must throw, not trap.
    func testOutOfRangeTimestampParameterThrows() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE ts (id INTEGER PRIMARY KEY, at TIMESTAMP)")
        for date in [Date(timeIntervalSince1970: 1.1e10), .distantFuture, .distantPast] {
            XCTAssertThrowsError(try db.execute("INSERT INTO ts VALUES ($1, $2)", [.integer(1), .timestamp(date)]))
            XCTAssertThrowsError(try db.prepare("INSERT INTO ts VALUES ($1, $2)")
                .executeBatch([[.integer(1), .timestamp(date)]]))
        }
        XCTAssertEqual(try db.queryOne("SELECT COUNT(*) FROM ts")?[0], .integer(0))
    }

    /// Thousands of parameters bound on a 512 KB secondary thread.
    func testManyParametersOnSmallStackThread() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE many (id INTEGER PRIMARY KEY, name TEXT)")
        let rows = 2500
        let placeholders = (0 ..< rows).map { "($\($0 * 2 + 1), $\($0 * 2 + 2))" }.joined(separator: ", ")
        var params: [Value] = []
        for i in 0 ..< rows {
            params.append(.integer(Int64(i)))
            params.append(.text("name-\(i)"))
        }
        var result: Result<Int64, Error>?
        let thread = Thread {
            result = Result { try db.execute("INSERT INTO many VALUES \(placeholders)", params) }
        }
        thread.stackSize = 512 * 1024
        let done = DispatchSemaphore(value: 0)
        let finished = Thread { thread.start(); while !thread.isFinished { usleep(1000) }; done.signal() }
        finished.start()
        done.wait()
        XCTAssertEqual(try result?.get(), Int64(rows))
        XCTAssertEqual(try db.queryOne("SELECT name FROM many WHERE id = 2499")?[0], .text("name-2499"))
    }

    /// The engine reads a BLOB parameter as packed f32 values; any other
    /// length used to be stored as NULL without an error.
    func testBlobMustBePackedFloats() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE b (id INTEGER PRIMARY KEY, v VECTOR(1))")
        XCTAssertThrowsError(try db.execute("INSERT INTO b VALUES ($1, $2)", [.integer(1), .blob(Data([1, 2, 3]))]))
        XCTAssertThrowsError(try db.prepare("INSERT INTO b VALUES ($1, $2)")
            .executeBatch([[.integer(1), .blob(Data([1, 2, 3, 4, 5]))]]))
        let one = Float(1).bitPattern.littleEndian
        try db.execute("INSERT INTO b VALUES ($1, $2)", [.integer(2), .blob(withUnsafeBytes(of: one) { Data($0) })])
        XCTAssertEqual(try db.queryOne("SELECT v FROM b WHERE id = 2")?[0], .vector([1]))
        XCTAssertEqual(try db.queryOne("SELECT COUNT(*) FROM b")?[0], .integer(1))
    }

    func testExecScriptWithCRLFLineComment() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE a (id INTEGER); -- note\r\nCREATE TABLE b (id INTEGER);\r\nCREATE TABLE c (id INTEGER);")
        for table in ["a", "b", "c"] {
            XCTAssertNoThrow(try db.query("SELECT * FROM \(table)"), table)
        }
    }

    func testExecScriptWithQuotesAndComments() throws {
        let db = try Database.open(":memory:")
        try db.exec("""
            CREATE TABLE q (id INTEGER PRIMARY KEY, s TEXT);
            INSERT INTO q VALUES (1, '5" disk'); /* a ; in a comment */
            INSERT INTO q VALUES (2, 'x -- y; z');
            INSERT INTO q VALUES (3, 'it''s');
            """)
        let rows = try db.query("SELECT s FROM q ORDER BY id")
        XCTAssertEqual(rows.map { $0[0] }, [.text("5\" disk"), .text("x -- y; z"), .text("it's")])
    }
}
