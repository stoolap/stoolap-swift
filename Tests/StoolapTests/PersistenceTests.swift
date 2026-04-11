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

/// Persistence tests: file-based database + reopen.
/// Mirrors `stoolap-python/tests/test_persistence.py`.
final class PersistenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("stoolap_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func dbPath(_ name: String = "testdb") -> String {
        tempDir.appendingPathComponent(name).path
    }

    func testFilePersistenceBasic() throws {
        let path = dbPath()

        do {
            let db = try Database.open(path)
            try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
            try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(2), .text("Bob")])
        }

        let db2 = try Database.open(path)
        let rows = try db2.query("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"]?.stringValue, "Alice")
        XCTAssertEqual(rows[1]["name"]?.stringValue, "Bob")
    }

    func testFilePersistenceWithIndex() throws {
        let path = dbPath()

        do {
            let db = try Database.open(path)
            try db.exec("""
                CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price FLOAT);
                CREATE INDEX idx_products_name ON products(name);
            """)
            try db.execute("INSERT INTO products VALUES ($1, $2, $3)",
                           [.integer(1), .text("Widget"), .float(9.99)])
            try db.execute("INSERT INTO products VALUES ($1, $2, $3)",
                           [.integer(2), .text("Gadget"), .float(19.99)])
        }

        let db2 = try Database.open(path)
        let row = try db2.queryOne("SELECT * FROM products WHERE name = $1", [.text("Widget")])
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["price"]?.doubleValue ?? 0, 9.99, accuracy: 0.001)
    }

    func testFilePersistenceUpdateDelete() throws {
        let path = dbPath()

        do {
            let db = try Database.open(path)
            try db.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)")
            try db.execute("INSERT INTO kv VALUES ($1, $2)", [.integer(1), .text("original")])
            try db.execute("INSERT INTO kv VALUES ($1, $2)", [.integer(2), .text("delete_me")])
            try db.execute("UPDATE kv SET v = $1 WHERE k = $2", [.text("updated"), .integer(1)])
            try db.execute("DELETE FROM kv WHERE k = $1", [.integer(2)])
        }

        let db2 = try Database.open(path)
        let rows = try db2.query("SELECT * FROM kv ORDER BY k")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["v"]?.stringValue, "updated")
    }

    func testFilePersistenceMultipleTables() throws {
        let path = dbPath()

        do {
            let db = try Database.open(path)
            try db.exec("""
                CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount FLOAT);
            """)
            try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .text("Alice")])
            try db.execute("INSERT INTO orders VALUES ($1, $2, $3)",
                           [.integer(100), .integer(1), .float(42.50)])
        }

        let db2 = try Database.open(path)
        let users = try db2.query("SELECT * FROM users")
        let orders = try db2.query("SELECT * FROM orders")
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(orders.count, 1)
        XCTAssertEqual(orders[0]["amount"]?.doubleValue ?? 0, 42.50, accuracy: 0.001)
    }

    func testFileURLPath() throws {
        // Also accept the explicit file:// form.
        let path = dbPath("file_url_db")
        let dsn = "file://\(path)"

        do {
            let db = try Database.open(dsn)
            try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
            try db.execute("INSERT INTO t VALUES ($1)", [.integer(42)])
        }

        let db2 = try Database.open(dsn)
        let row = try db2.queryOne("SELECT id FROM t")
        XCTAssertEqual(row?["id"]?.int64Value, 42)
    }
}
