# stoolap-swift

High-performance Swift driver for [Stoolap](https://stoolap.io) embedded SQL database. Calls the Rust engine directly through the official C ABI with zero intermediate wrappers. Provides sync, async, and streaming cursor APIs.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/stoolap/stoolap-swift.git", from: "0.4.1")
]
```

Requires:
- macOS 12+ or iOS 15+
- The `libstoolap_c` shared library (see [Building from Source](#building-from-source))

## Quick Start

```swift
import Stoolap

let db = try Database.open(":memory:")

try db.exec("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT
    )
""")

// Insert with positional parameters ($1, $2, ...)
try db.execute(
    "INSERT INTO users (id, name, email) VALUES ($1, $2, $3)",
    [.integer(1), .text("Alice"), .text("alice@example.com")]
)

// Query rows
let users = try db.query("SELECT * FROM users ORDER BY id")
for user in users {
    print(user["name"]?.stringValue ?? "")
}

// Single-row shortcut
let one = try db.queryOne("SELECT * FROM users WHERE id = $1", [.integer(1)])

// Flat columnar result (zero per-row allocation)
let raw = try db.queryRaw("SELECT id, name FROM users")
print(raw.columns)         // ["id", "name"]
print(raw[row: 0])         // [.integer(1), .text("Alice")]
print(Array(raw.column(at: 1)))  // [.text("Alice")]

// Streaming cursor (bounded memory for large results)
let cursor = try db.queryCursor("SELECT * FROM users ORDER BY id")
while try cursor.next() {
    print(try cursor.value(named: "name")?.stringValue ?? "")
}
```

## Opening a Database

```swift
// In-memory
let db = try Database.open(":memory:")
let db = try Database.open("")
let db = try Database.open("memory://")

// File-based (data persists across restarts)
let db = try Database.open("./mydata")
let db = try Database.open("file:///absolute/path/to/db")
```

## Methods

### Database

| Method | Returns | Description |
|--------|---------|-------------|
| `execute(sql, params?)` | `Int64` | Execute DML statement, return rows affected |
| `exec(sql)` | `Void` | Execute one or more semicolon-separated statements |
| `query(sql, params?)` | `[Row]` | Query rows with named column access |
| `queryOne(sql, params?)` | `Row?` | Query single row |
| `queryRaw(sql, params?)` | `ColumnarResult` | Query in flat columnar format |
| `queryCursor(sql, params?)` | `RowCursor` | Streaming cursor over result set |
| `prepare(sql)` | `PreparedStatement` | Create a prepared statement |
| `begin()` | `Transaction` | Begin a transaction |
| `withTransaction(_:)` | Generic | Execute closure in auto-commit/rollback transaction |

### Row

| Access | Example | Notes |
|--------|---------|-------|
| By name | `row["name"]` | Returns `Value?`, O(N) scan on column count |
| By index | `row[0]` | Returns `Value`, zero-based |
| Iterate | `row.forEach { name, value in }` | Column name and value pairs |

### ColumnarResult

| Access | Example | Notes |
|--------|---------|-------|
| Row count | `raw.rowCount` | Total rows |
| Row slice | `raw[row: 0]` | `ArraySlice<Value>`, zero allocation |
| Single cell | `raw[row: 0, column: 1]` | Direct cell access |
| Column view | `raw.column(at: 0)` | Zero-allocation strided `RandomAccessCollection` |
| Column by name | `raw.column(named: "id")` | Returns `ColumnarColumn?` |

### RowCursor

| Method | Returns | Description |
|--------|---------|-------------|
| `next()` | `Bool` | Advance to next row, `false` when exhausted |
| `row()` | `Row` | Materialize current row |
| `value(at:)` | `Value` | Read cell by column index |
| `value(named:)` | `Value?` | Read cell by column name |
| `forEachRemaining(_:)` | `Void` | Drain remainder with bounded memory |
| `close()` | `Void` | Close cursor early (also called by deinit) |

## Persistence

File-based databases persist data to disk using WAL (Write-Ahead Logging) and immutable cold volumes. A background checkpoint cycle seals hot rows into columnar volume files, compacts them, and truncates the WAL.

```swift
let db = try Database.open("./mydata")

try db.exec("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT)")
try db.execute("INSERT INTO kv VALUES ($1, $2)", [.text("hello"), .text("world")])
// Data survives process restarts
```

### Configuration

Pass configuration as query parameters in the path:

```swift
// Maximum durability
let db = try Database.open("./mydata?sync=full")

// High throughput
let db = try Database.open("./mydata?sync=none&wal_buffer_size=131072")

// Custom checkpoint interval with compression
let db = try Database.open("./mydata?checkpoint_interval=60&compression=on")
```

### All Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `sync` | `normal` | Sync mode: `none`, `normal`, or `full` |
| `checkpoint_interval` | `60` | Seconds between automatic checkpoint cycles |
| `compact_threshold` | `4` | Sub-target volumes per table before merging |
| `wal_flush_trigger` | `32768` | WAL flush trigger size in bytes (32 KB) |
| `wal_buffer_size` | `65536` | WAL buffer size in bytes (64 KB) |
| `wal_max_size` | `67108864` | Max WAL file size before rotation (64 MB) |
| `commit_batch_size` | `100` | Commits to batch before syncing (normal mode) |
| `sync_interval_ms` | `1000` | Minimum ms between syncs (normal mode) |
| `wal_compression` | `on` | LZ4 compression for WAL entries |
| `volume_compression` | `on` | LZ4 compression for cold volume files |
| `compression` | -- | Alias that sets both `wal_compression` and `volume_compression` |
| `compression_threshold` | `64` | Minimum bytes before compressing an entry |
| `checkpoint_on_close` | `on` | Seal all hot rows to volumes on clean shutdown |
| `target_volume_rows` | `1048576` | Target rows per cold volume (min 65536) |

## Prepared Statements

Prepared statements parse SQL once and reuse the cached execution plan on every call. Column names are cached after the first execution.

```swift
let insert = try db.prepare("INSERT INTO users VALUES ($1, $2, $3)")
try insert.execute([.integer(1), .text("Alice"), .text("alice@example.com")])
try insert.execute([.integer(2), .text("Bob"), .text("bob@example.com")])

let lookup = try db.prepare("SELECT * FROM users WHERE id = $1")
let user = try lookup.queryOne([.integer(1)])
// Row with user["name"] == .text("Alice")
```

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `execute(params?)` | `Int64` | Execute DML statement |
| `query(params?)` | `[Row]` | Query rows |
| `queryOne(params?)` | `Row?` | Query single row |
| `queryRaw(params?)` | `ColumnarResult` | Query in columnar format |
| `queryCursor(params?)` | `RowCursor` | Streaming cursor |
| `executeBatch(paramsList)` | `Int64` | Execute with multiple param sets |

Property: `sql` returns the SQL text of this prepared statement.

## Batch Execution

Execute the same SQL with multiple parameter sets in a single FFI call. Automatically wraps in a transaction.

```swift
let insert = try db.prepare("INSERT INTO users VALUES ($1, $2, $3)")
let changes = try insert.executeBatch([
    [.integer(1), .text("Alice"), .text("alice@example.com")],
    [.integer(2), .text("Bob"), .text("bob@example.com")],
    [.integer(3), .text("Charlie"), .text("charlie@example.com")],
])
// changes == 3
```

## Transactions

### Auto-commit/rollback

```swift
try db.withTransaction { tx in
    try tx.execute("INSERT INTO users VALUES ($1, $2, $3)",
                   [.integer(1), .text("Alice"), .text("alice@example.com")])
    try tx.execute("INSERT INTO users VALUES ($1, $2, $3)",
                   [.integer(2), .text("Bob"), .text("bob@example.com")])
    // Auto-commits on clean return, auto-rollbacks on throw
}
```

### Manual control

```swift
let tx = try db.begin()
do {
    try tx.execute("INSERT INTO users VALUES ($1, $2, $3)",
                   [.integer(1), .text("Alice"), .text("alice@example.com")])
    try tx.commit()
} catch {
    try? tx.rollback()
    throw error
}
```

### Transaction Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `execute(sql, params?)` | `Int64` | Execute DML statement |
| `query(sql, params?)` | `[Row]` | Query rows |
| `queryOne(sql, params?)` | `Row?` | Query single row |
| `queryRaw(sql, params?)` | `ColumnarResult` | Query in columnar format |
| `commit()` | `Void` | Commit the transaction |
| `rollback()` | `Void` | Rollback the transaction |

## Async API

`AsyncDatabase` wraps `Database` with Swift concurrency. All calls hop to a detached task so they do not block the cooperative thread pool.

```swift
import Stoolap

let db = try await AsyncDatabase.open(":memory:")

try await db.exec("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT
    )
""")

try await db.execute(
    "INSERT INTO users VALUES ($1, $2, $3)",
    [.integer(1), .text("Alice"), .text("alice@example.com")]
)

let users = try await db.query("SELECT * FROM users")
print(users)
```

## Error Handling

All methods throw `StoolapError` on failure (invalid SQL, constraint violations, etc.):

```swift
do {
    try db.execute("INSERT INTO users VALUES ($1, $2)", [.integer(1), .null])
} catch let error as StoolapError {
    print("Database error: \(error.message)")
}

// Invalid SQL raises at prepare time
do {
    _ = try db.prepare("INVALID SQL HERE")
} catch let error as StoolapError {
    print("Parse error: \(error.message)")
}
```

## Type Mapping

| Swift | Stoolap | Notes |
|-------|---------|-------|
| `.integer(Int64)` | `INTEGER` | 64-bit signed |
| `.float(Double)` | `FLOAT` | 64-bit double |
| `.text(String)` | `TEXT` | UTF-8 encoded |
| `.boolean(Bool)` | `BOOLEAN` | |
| `.null` | `NULL` | Any type |
| `.timestamp(Date)` | `TIMESTAMP` | Nanosecond precision |
| `.json(String)` | `JSON` | Pre-serialized JSON string |
| `.blob(Data)` | `BLOB` | Raw bytes |
| `.vector([Float])` | `VECTOR` | Packed f32 array for similarity search |

## Architecture

The driver uses three read strategies depending on the query:

| Method | Strategy | Best for |
|--------|----------|----------|
| `query()`, `queryRaw()` | `stoolap_rows_fetch_all` bulk buffer | Multi-row results |
| `queryOne()` | `stoolap_rows_next` cursor (1 step) | Single-row lookups |
| `queryCursor()` | `stoolap_rows_next` streaming cursor | Large results with bounded memory |

All parameter binding uses stack allocation for up to 16 params. Batch execution flattens all rows into a shared arena and makes one FFI call. Column names are cached on prepared statements after the first execution.

## Building from Source

Requires:
- [Rust](https://rustup.rs) (stable)
- [Swift](https://swift.org/download/) 5.9+
- macOS 12+ or iOS 15+

```bash
git clone https://github.com/stoolap/stoolap-swift.git
cd stoolap-swift

# Build the Rust shared library
cd crates/stoolap-c
cargo build --release
cd ../..

# Build and test the Swift package
swift build
swift test
```

## License

Apache License 2.0
