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

/// Vector type and similarity search tests.
/// Mirrors `stoolap-python/tests/test_vector.py`.
final class VectorTests: XCTestCase {
    func testVectorInsertAndQuery() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE embeddings (id INTEGER PRIMARY KEY, embedding VECTOR(3))")

        try db.execute("INSERT INTO embeddings VALUES ($1, $2)",
                       [.integer(1), .vector([0.1, 0.2, 0.3])])
        try db.execute("INSERT INTO embeddings VALUES ($1, $2)",
                       [.integer(2), .vector([0.4, 0.5, 0.6])])

        let rows = try db.query("SELECT id, embedding FROM embeddings ORDER BY id")
        XCTAssertEqual(rows.count, 2)

        guard case let .vector(v1)? = rows[0]["embedding"] else {
            XCTFail("expected vector for row 0")
            return
        }
        XCTAssertEqual(v1.count, 3)
        XCTAssertEqual(v1[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(v1[1], 0.2, accuracy: 1e-6)
        XCTAssertEqual(v1[2], 0.3, accuracy: 1e-6)

        guard case let .vector(v2)? = rows[1]["embedding"] else {
            XCTFail("expected vector for row 1")
            return
        }
        XCTAssertEqual(v2[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(v2[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(v2[2], 0.6, accuracy: 1e-6)
    }

    func testVectorInsertStringLiteral() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")
        try db.exec("INSERT INTO t VALUES (1, '[0.1, 0.2, 0.3]')")

        let row = try db.queryOne("SELECT v FROM t WHERE id = 1")
        guard case let .vector(v)? = row?["v"] else {
            XCTFail("expected vector")
            return
        }
        XCTAssertEqual(v.count, 3)
        XCTAssertEqual(v[0], 0.1, accuracy: 1e-6)
    }

    func testVectorNull() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .null])

        let row = try db.queryOne("SELECT v FROM t WHERE id = 1")
        XCTAssertEqual(row?["v"], .null)
    }

    func testVectorL2Distance() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .vector([1.0, 0.0, 0.0])])
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(2), .vector([0.0, 1.0, 0.0])])

        let rows = try db.query(
            "SELECT id, VEC_DISTANCE_L2(v, '[1.0, 0.0, 0.0]') AS dist FROM t ORDER BY dist"
        )
        XCTAssertEqual(rows[0]["id"]?.int64Value, 1)
        let d0 = rows[0]["dist"]?.doubleValue ?? -1
        XCTAssertEqual(d0, 0.0, accuracy: 1e-6)
        XCTAssertEqual(rows[1]["id"]?.int64Value, 2)
        let d1 = rows[1]["dist"]?.doubleValue ?? -1
        XCTAssertEqual(d1, 2.0.squareRoot(), accuracy: 1e-6)
    }

    func testVectorCosineDistance() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .vector([1.0, 0.0, 0.0])])
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(2), .vector([0.0, 1.0, 0.0])])
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(3), .vector([1.0, 0.0, 0.0])])

        let rows = try db.query(
            "SELECT id, VEC_DISTANCE_COSINE(v, '[1.0, 0.0, 0.0]') AS dist FROM t ORDER BY dist"
        )
        // id=1 and id=3 collinear with query -> distance 0
        XCTAssertEqual(rows[0]["dist"]?.doubleValue ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertEqual(rows[1]["dist"]?.doubleValue ?? -1, 0.0, accuracy: 1e-6)
        // id=2 orthogonal -> distance 1
        XCTAssertEqual(rows[2]["dist"]?.doubleValue ?? -1, 1.0, accuracy: 1e-6)
    }

    func testVectorDims() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(5))")
        try db.execute("INSERT INTO t VALUES ($1, $2)",
                       [.integer(1), .vector([1.0, 2.0, 3.0, 4.0, 5.0])])

        let row = try db.queryOne("SELECT VEC_DIMS(v) AS dims FROM t WHERE id = 1")
        XCTAssertEqual(row?["dims"]?.int64Value, 5)
    }

    func testVectorNorm() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")
        try db.execute("INSERT INTO t VALUES ($1, $2)", [.integer(1), .vector([3.0, 4.0, 0.0])])

        let row = try db.queryOne("SELECT VEC_NORM(v) AS norm FROM t WHERE id = 1")
        XCTAssertEqual(row?["norm"]?.doubleValue ?? 0, 5.0, accuracy: 1e-6)
    }

    func testVectorKNNSearch() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, v VECTOR(3))")

        let vectors: [(Int64, [Float])] = [
            (1, [1.0, 0.0, 0.0]),
            (2, [0.0, 1.0, 0.0]),
            (3, [0.0, 0.0, 1.0]),
            (4, [0.9, 0.1, 0.0]),
            (5, [0.0, 0.9, 0.1]),
        ]
        for (i, v) in vectors {
            try db.execute("INSERT INTO items VALUES ($1, $2)", [.integer(i), .vector(v)])
        }

        let rows = try db.query(
            "SELECT id, VEC_DISTANCE_L2(v, '[1.0, 0.0, 0.0]') AS dist " +
                "FROM items ORDER BY dist LIMIT 2"
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"]?.int64Value, 1)
        XCTAssertEqual(rows[1]["id"]?.int64Value, 4)
    }

    func testVectorBatchInsert() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(2))")

        let stmt = try db.prepare("INSERT INTO t VALUES ($1, $2)")
        let batch: [[Value]] = (1 ... 5).map { i in
            [.integer(Int64(i)), .vector([Float(i), Float(i + 1)])]
        }
        let count = try stmt.executeBatch(batch)
        XCTAssertEqual(count, 5)

        let rows = try db.query("SELECT * FROM t ORDER BY id")
        XCTAssertEqual(rows.count, 5)
        if case let .vector(v)? = rows[0]["v"] {
            XCTAssertEqual(v[0], 1.0, accuracy: 1e-6)
        } else {
            XCTFail("expected vector")
        }
        if case let .vector(v)? = rows[4]["v"] {
            XCTAssertEqual(v[1], 6.0, accuracy: 1e-6)
        } else {
            XCTFail("expected vector")
        }
    }

    func testVectorInTransaction() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")

        let tx = try db.begin()
        try tx.execute("INSERT INTO t VALUES ($1, $2)",
                       [.integer(1), .vector([1.0, 2.0, 3.0])])
        try tx.execute("INSERT INTO t VALUES ($1, $2)",
                       [.integer(2), .vector([4.0, 5.0, 6.0])])
        try tx.commit()

        let rows = try db.query("SELECT * FROM t ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        if case let .vector(v)? = rows[1]["v"] {
            XCTAssertEqual(v[2], 6.0, accuracy: 1e-6)
        } else {
            XCTFail("expected vector")
        }
    }

    func testVectorTransactionRollback() throws {
        let db = try Database.open(":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v VECTOR(3))")

        let tx = try db.begin()
        try tx.execute("INSERT INTO t VALUES ($1, $2)",
                       [.integer(1), .vector([1.0, 2.0, 3.0])])
        try tx.rollback()

        let rows = try db.query("SELECT * FROM t")
        XCTAssertEqual(rows.count, 0)
    }
}
