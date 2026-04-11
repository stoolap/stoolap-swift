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

import CStoolap
import Foundation

/// Binds a batch of `[Value]` rows into a single flat `StoolapValue`
/// array plus shared text/binary arenas. This avoids the per-cell heap
/// allocation churn that `strdup`/individual byte buffers caused in the
/// hot batch-insert path.
@usableFromInline
enum BatchParameterBinder {
    @inlinable
    static func withBoundBatch<R>(
        _ batch: [[Value]],
        _ body: (UnsafePointer<StoolapValue>, Int32, Int32) throws -> R
    ) throws -> R {
        let width = batch[0].count
        let rowCount = batch.count
        let cellCount = rowCount * width

        var textArenaBytes = 0
        var binaryArenaBytes = 0

        for row in batch {
            for value in row {
                switch value {
                case let .text(s), let .json(s):
                    textArenaBytes += max(s.utf8.count, 1)
                case let .blob(data):
                    binaryArenaBytes += max(data.count, 1)
                case let .vector(floats):
                    binaryArenaBytes += max(floats.count * 4, 1)
                default:
                    break
                }
            }
        }

        let values = UnsafeMutableBufferPointer<StoolapValue>.allocate(capacity: cellCount)
        defer { values.deallocate() }

        let textArena = textArenaBytes > 0
            ? UnsafeMutableRawBufferPointer.allocate(byteCount: textArenaBytes, alignment: 1)
            : nil
        defer { textArena?.deallocate() }

        let binaryArena = binaryArenaBytes > 0
            ? UnsafeMutableRawBufferPointer.allocate(byteCount: binaryArenaBytes, alignment: 4)
            : nil
        defer { binaryArena?.deallocate() }

        var textOffset = 0
        var binaryOffset = 0

        for (r, row) in batch.enumerated() {
            for (c, value) in row.enumerated() {
                let idx = r * width + c
                switch value {
                case .null:
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_NULL,
                        _padding: 0,
                        v: StoolapValueData(integer: 0)
                    )

                case let .integer(i):
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_INTEGER,
                        _padding: 0,
                        v: StoolapValueData(integer: i)
                    )

                case let .float(f):
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_FLOAT,
                        _padding: 0,
                        v: StoolapValueData(float64: f)
                    )

                case let .boolean(b):
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_BOOLEAN,
                        _padding: 0,
                        v: StoolapValueData(boolean: b ? 1 : 0)
                    )

                case let .timestamp(date):
                    let nanos = Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_TIMESTAMP,
                        _padding: 0,
                        v: StoolapValueData(timestamp_nanos: nanos)
                    )

                case let .text(s):
                    let len = s.utf8.count
                    let span = max(len, 1)
                    let dest = textArena!.baseAddress!
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: textOffset)
                    copyUTF8(s, to: dest, count: len)
                    if len == 0 { dest[0] = 0 }
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_TEXT,
                        _padding: 0,
                        v: StoolapValueData(
                            text: StoolapTextData(
                                ptr: UnsafePointer<CChar>(OpaquePointer(dest)),
                                len: Int64(len)
                            )
                        )
                    )
                    textOffset += span

                case let .json(s):
                    let len = s.utf8.count
                    let span = max(len, 1)
                    let dest = textArena!.baseAddress!
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: textOffset)
                    copyUTF8(s, to: dest, count: len)
                    if len == 0 { dest[0] = 0 }
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_JSON,
                        _padding: 0,
                        v: StoolapValueData(
                            text: StoolapTextData(
                                ptr: UnsafePointer<CChar>(OpaquePointer(dest)),
                                len: Int64(len)
                            )
                        )
                    )
                    textOffset += span

                case let .blob(data):
                    let len = data.count
                    let span = max(len, 1)
                    let dest = binaryArena!.baseAddress!
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: binaryOffset)
                    if len > 0 {
                        data.copyBytes(to: dest, count: len)
                    } else {
                        dest[0] = 0
                    }
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_BLOB,
                        _padding: 0,
                        v: StoolapValueData(
                            blob: StoolapBlobData(ptr: UnsafePointer(dest), len: Int64(len))
                        )
                    )
                    binaryOffset += span

                case let .vector(floats):
                    let byteCount = floats.count * 4
                    let span = max(byteCount, 1)
                    let dest = binaryArena!.baseAddress!
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: binaryOffset)
                    if byteCount > 0 {
                        writeVector(floats, to: dest)
                    } else {
                        dest[0] = 0
                    }
                    values[idx] = StoolapValue(
                        value_type: STOOLAP_TYPE_BLOB,
                        _padding: 0,
                        v: StoolapValueData(
                            blob: StoolapBlobData(ptr: UnsafePointer(dest), len: Int64(byteCount))
                        )
                    )
                    binaryOffset += span
                }
            }
        }

        return try body(values.baseAddress!, Int32(width), Int32(rowCount))
    }

    @inlinable
    @inline(__always)
    static func copyUTF8(_ string: String, to dest: UnsafeMutablePointer<UInt8>, count: Int) {
        if count == 0 { return }
        if string.utf8.withContiguousStorageIfAvailable({ src in
            dest.initialize(from: src.baseAddress!, count: count)
        }) != nil {
            return
        }
        string.withCString { cstr in
            let src = UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self)
            dest.initialize(from: src, count: count)
        }
    }

    @inlinable
    @inline(__always)
    static func writeVector(_ floats: [Float], to dest: UnsafeMutablePointer<UInt8>) {
        var off = 0
        for f in floats {
            let bits = f.bitPattern.littleEndian
            withUnsafeBytes(of: bits) { src in
                for i in 0 ..< 4 {
                    dest[off + i] = src[i]
                }
            }
            off += 4
        }
    }
}
