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

/// Unit tests for the `Value` enum and its convenience accessors.
final class ValueTests: XCTestCase {
    func testIsNull() {
        XCTAssertTrue(Value.null.isNull)
        XCTAssertFalse(Value.integer(0).isNull)
        XCTAssertFalse(Value.text("").isNull)
        XCTAssertFalse(Value.boolean(false).isNull)
    }

    func testInt64Value() {
        XCTAssertEqual(Value.integer(42).int64Value, 42)
        XCTAssertNil(Value.null.int64Value)
        XCTAssertNil(Value.float(1.5).int64Value)
        XCTAssertNil(Value.text("42").int64Value)
    }

    func testDoubleValue() {
        XCTAssertEqual(Value.float(3.14).doubleValue, 3.14)
        XCTAssertNil(Value.null.doubleValue)
        XCTAssertNil(Value.integer(3).doubleValue)
    }

    func testStringValue() {
        XCTAssertEqual(Value.text("hi").stringValue, "hi")
        // .json should also surface as stringValue
        XCTAssertEqual(Value.json("{}").stringValue, "{}")
        XCTAssertNil(Value.null.stringValue)
        XCTAssertNil(Value.integer(1).stringValue)
        XCTAssertNil(Value.boolean(true).stringValue)
    }

    func testBoolValue() {
        XCTAssertEqual(Value.boolean(true).boolValue, true)
        XCTAssertEqual(Value.boolean(false).boolValue, false)
        XCTAssertNil(Value.null.boolValue)
        XCTAssertNil(Value.integer(1).boolValue)
    }

    func testDateValue() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(Value.timestamp(date).dateValue, date)
        XCTAssertNil(Value.null.dateValue)
        XCTAssertNil(Value.integer(0).dateValue)
    }

    func testEquatable() {
        XCTAssertEqual(Value.null, Value.null)
        XCTAssertEqual(Value.integer(5), Value.integer(5))
        XCTAssertNotEqual(Value.integer(5), Value.integer(6))
        XCTAssertEqual(Value.text("a"), Value.text("a"))
        XCTAssertNotEqual(Value.text("a"), Value.text("b"))
        XCTAssertEqual(Value.vector([1.0, 2.0]), Value.vector([1.0, 2.0]))
        XCTAssertNotEqual(Value.vector([1.0]), Value.vector([2.0]))
    }

    func testHashable() {
        // Must be usable as dict key / set element.
        var set: Set<Value> = []
        set.insert(.integer(1))
        set.insert(.integer(1))
        set.insert(.text("hi"))
        XCTAssertEqual(set.count, 2)
    }

    func testBlobEquality() {
        let a = Value.blob(Data([1, 2, 3]))
        let b = Value.blob(Data([1, 2, 3]))
        let c = Value.blob(Data([1, 2, 4]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
