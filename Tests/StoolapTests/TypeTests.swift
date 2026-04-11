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
@testable import Stoolap
import XCTest

/// Type mapping and conversion tests. Mirrors `stoolap-python/tests/test_types.py`.
final class TypeTests: XCTestCase {
    func testIntegerTypes() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t_int (val INTEGER)")

        try db.execute("INSERT INTO t_int VALUES ($1)", [.integer(0)])
        try db.execute("INSERT INTO t_int VALUES ($1)", [.integer(42)])
        try db.execute("INSERT INTO t_int VALUES ($1)", [.integer(-100)])
        let big: Int64 = 1 << 53
        try db.execute("INSERT INTO t_int VALUES ($1)", [.integer(big)])

        let rows = try db.query("SELECT val FROM t_int ORDER BY val")
        XCTAssertEqual(rows[0]["val"]?.int64Value, -100)
        XCTAssertEqual(rows[1]["val"]?.int64Value, 0)
        XCTAssertEqual(rows[2]["val"]?.int64Value, 42)
        XCTAssertEqual(rows[3]["val"]?.int64Value, big)
    }

    func testIntegerBoundaries() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (val INTEGER)")
        try db.execute("INSERT INTO t VALUES ($1)", [.integer(Int64.max)])
        try db.execute("INSERT INTO t VALUES ($1)", [.integer(Int64.min)])
        let rows = try db.query("SELECT val FROM t ORDER BY val")
        XCTAssertEqual(rows[0]["val"]?.int64Value, Int64.min)
        XCTAssertEqual(rows[1]["val"]?.int64Value, Int64.max)
    }

    func testFloatTypes() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t_float (val FLOAT)")

        try db.execute("INSERT INTO t_float VALUES ($1)", [.float(0.0)])
        try db.execute("INSERT INTO t_float VALUES ($1)", [.float(3.14159)])
        try db.execute("INSERT INTO t_float VALUES ($1)", [.float(-1.5)])
        try db.execute("INSERT INTO t_float VALUES ($1)", [.float(1e10)])

        let rows = try db.query("SELECT val FROM t_float ORDER BY val")
        XCTAssertEqual(rows[0]["val"]?.doubleValue ?? 0, -1.5, accuracy: 0.001)
        XCTAssertEqual(rows[1]["val"]?.doubleValue ?? 0, 0.0, accuracy: 0.001)
        XCTAssertEqual(rows[2]["val"]?.doubleValue ?? 0, 3.14159, accuracy: 0.001)
        XCTAssertEqual(rows[3]["val"]?.doubleValue ?? 0, 1e10, accuracy: 1.0)
    }

    func testTextTypes() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")

        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .text("")])
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(2), .text("hello world")])
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(3), .text("unicode: éàüñ")])
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(4), .text("emoji: 😀")])

        let rows = try db.query("SELECT id, val FROM t ORDER BY id")
        XCTAssertEqual(rows[0]["val"]?.stringValue, "")
        XCTAssertEqual(rows[1]["val"]?.stringValue, "hello world")
        XCTAssertEqual(rows[2]["val"]?.stringValue, "unicode: éàüñ")
        XCTAssertEqual(rows[3]["val"]?.stringValue, "emoji: 😀")
    }

    func testTextWithMultibyteLength() throws {
        // UTF-8 multi-byte chars: `utf8.count` must be used, not `count`.
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
        // 10 emoji × 4 bytes each = 40 bytes, but .count == 10.
        let text = String(repeating: "😀", count: 10)
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .text(text)])
        let row = try db.queryOne("SELECT val FROM t WHERE id = 1")
        XCTAssertEqual(row?["val"]?.stringValue, text)
    }

    func testBooleanType() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t_bool (id INTEGER PRIMARY KEY, val BOOLEAN)")
        try db.execute("INSERT INTO t_bool VALUES ($1, $2)", [.integer(1), .boolean(true)])
        try db.execute("INSERT INTO t_bool VALUES ($1, $2)", [.integer(2), .boolean(false)])

        let rows = try db.query("SELECT val FROM t_bool ORDER BY id")
        XCTAssertEqual(rows[0]["val"]?.boolValue, true)
        XCTAssertEqual(rows[1]["val"]?.boolValue, false)
    }

    func testNullType() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t_null (id INTEGER PRIMARY KEY, val TEXT)")
        try db.execute("INSERT INTO t_null VALUES ($1, $2)", [.integer(1), .null])

        let row = try db.queryOne("SELECT val FROM t_null WHERE id = $1", [.integer(1)])
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["val"], .null)
        XCTAssertTrue(row?["val"]?.isNull ?? false)
    }

    func testDatetimeUTCRoundtrip() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t_ts (id INTEGER PRIMARY KEY, ts TIMESTAMP)")

        // 2024-06-15 12:30:45 UTC
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 6
        comps.day = 15
        comps.hour = 12
        comps.minute = 30
        comps.second = 45
        comps.timeZone = TimeZone(identifier: "UTC")
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: comps))

        try db.execute("INSERT INTO t_ts VALUES ($1, $2)", [.integer(1), .timestamp(date)])

        let row = try db.queryOne("SELECT ts FROM t_ts WHERE id = $1", [.integer(1)])
        let back = row?["ts"]?.dateValue
        XCTAssertNotNil(back)
        if let back = back {
            XCTAssertEqual(back.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.000001)
        }
    }

    func testTimestampSubmicroRoundtrip() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, ts TIMESTAMP)")
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .timestamp(date)])
        let row = try db.queryOne("SELECT ts FROM t WHERE id = 1")
        let back = row?["ts"]?.dateValue
        XCTAssertNotNil(back)
        if let back = back {
            XCTAssertEqual(back.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.000001)
        }
    }

    func testJSONRoundtrip() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, data JSON)")
        let payload = "{\"name\":\"Alice\",\"age\":30}"
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .json(payload)])

        let row = try db.queryOne("SELECT data FROM t WHERE id = $1", [.integer(1)])
        XCTAssertEqual(row?["data"]?.stringValue, payload)
    }

    func testMixedTypesInQuery() throws {
        let db = try Database.open(":memory:")
        try db.exec("""
            CREATE TABLE t_mixed (
                id INTEGER PRIMARY KEY,
                name TEXT,
                score FLOAT,
                active BOOLEAN,
                note TEXT
            )
        """)
        try db.execute(
            "INSERT INTO t_mixed VALUES ($1, $2, $3, $4, $5)",
            [.integer(1), .text("Alice"), .float(95.5), .boolean(true), .null]
        )

        let row = try db.queryOne("SELECT * FROM t_mixed WHERE id = $1", [.integer(1)])
        XCTAssertEqual(row?["id"]?.int64Value, 1)
        XCTAssertEqual(row?["name"]?.stringValue, "Alice")
        XCTAssertEqual(row?["score"]?.doubleValue ?? 0, 95.5, accuracy: 0.001)
        XCTAssertEqual(row?["active"]?.boolValue, true)
        XCTAssertEqual(row?["note"], .null)
    }

    func testIntegerConversionFromParams() throws {
        // Make sure small-int params round-trip correctly.
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (val INTEGER)")
        for n in [Int64(-128), -1, 0, 1, 127] {
            try db.execute("INSERT INTO t VALUES ($1)", [.integer(n)])
        }
        let rows = try db.query("SELECT val FROM t ORDER BY val")
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0]["val"]?.int64Value, -128)
        XCTAssertEqual(rows[4]["val"]?.int64Value, 127)
    }
}
