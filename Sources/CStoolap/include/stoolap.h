/*
 * Copyright 2025 Stoolap Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * C header for the official Stoolap C ABI (the `ffi` feature in the
 * upstream `stoolap` Rust crate). The Swift driver calls these functions
 * directly via the CStoolap module — there is no intermediate wrapper.
 *
 * This is the same API that the .NET (P/Invoke) driver uses. It follows
 * the SQLite cursor pattern: open -> query -> step -> column-accessors
 * -> close. Per-call FFI overhead is the bottleneck for small queries on
 * any host with cheap C interop, so this design is preferable to bulk
 * binary buffers (which only win on JNI-style high-overhead hosts).
 */

#ifndef STOOLAP_H
#define STOOLAP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 *  Status codes
 * ------------------------------------------------------------------ */

#define STOOLAP_OK     0
#define STOOLAP_ERROR  1
#define STOOLAP_ROW    100
#define STOOLAP_DONE   101

/* ------------------------------------------------------------------ *
 *  Type codes (StoolapValue.value_type, stoolap_rows_column_type)
 * ------------------------------------------------------------------ */

#define STOOLAP_TYPE_NULL      0
#define STOOLAP_TYPE_INTEGER   1
#define STOOLAP_TYPE_FLOAT     2
#define STOOLAP_TYPE_TEXT      3
#define STOOLAP_TYPE_BOOLEAN   4
#define STOOLAP_TYPE_TIMESTAMP 5
#define STOOLAP_TYPE_JSON      6
#define STOOLAP_TYPE_BLOB      7

/* ------------------------------------------------------------------ *
 *  Isolation levels
 * ------------------------------------------------------------------ */

#define STOOLAP_ISOLATION_READ_COMMITTED 0
#define STOOLAP_ISOLATION_SNAPSHOT       1

/* ------------------------------------------------------------------ *
 *  Opaque handles. Never dereference; only pass back to stoolap_*
 * ------------------------------------------------------------------ */

typedef struct StoolapDB   StoolapDB;
typedef struct StoolapStmt StoolapStmt;
typedef struct StoolapTx   StoolapTx;
typedef struct StoolapRows StoolapRows;

/* ------------------------------------------------------------------ *
 *  Tagged value types for parameter binding
 * ------------------------------------------------------------------ */

typedef struct {
    const char* ptr;
    int64_t     len;   /* byte length, NOT including any NUL */
} StoolapTextData;

typedef struct {
    const uint8_t* ptr;
    int64_t        len;
} StoolapBlobData;

/* C union: only one field is live at a time, selected by value_type. */
typedef union {
    int64_t          integer;
    double           float64;
    int32_t          boolean;
    StoolapTextData  text;
    StoolapBlobData  blob;
    int64_t          timestamp_nanos;
} StoolapValueData;

typedef struct {
    int32_t          value_type;   /* STOOLAP_TYPE_* */
    int32_t          _padding;     /* explicit pad so the union is 8-byte aligned */
    StoolapValueData v;
} StoolapValue;

/* ------------------------------------------------------------------ *
 *  Database lifecycle
 * ------------------------------------------------------------------ */

const char* stoolap_version(void);

int32_t     stoolap_open(const char* dsn, StoolapDB** out_db);
int32_t     stoolap_open_in_memory(StoolapDB** out_db);
int32_t     stoolap_close(StoolapDB* db);
int32_t     stoolap_clone(const StoolapDB* db, StoolapDB** out_db);
const char* stoolap_errmsg(const StoolapDB* db);

void        stoolap_string_free(char* s);

/* ------------------------------------------------------------------ *
 *  Execute / Query (auto-commit on the database)
 * ------------------------------------------------------------------ */

int32_t stoolap_exec(StoolapDB* db,
                     const char* sql,
                     int64_t* rows_affected);

int32_t stoolap_exec_params(StoolapDB* db,
                            const char* sql,
                            const StoolapValue* params,
                            int32_t params_len,
                            int64_t* rows_affected);

int32_t stoolap_query(StoolapDB* db,
                      const char* sql,
                      StoolapRows** out_rows);

int32_t stoolap_query_params(StoolapDB* db,
                             const char* sql,
                             const StoolapValue* params,
                             int32_t params_len,
                             StoolapRows** out_rows);

/* ------------------------------------------------------------------ *
 *  Prepared statements
 * ------------------------------------------------------------------ */

int32_t     stoolap_prepare(StoolapDB* db,
                            const char* sql,
                            StoolapStmt** out_stmt);

int32_t     stoolap_stmt_exec(StoolapStmt* stmt,
                              const StoolapValue* params,
                              int32_t params_len,
                              int64_t* rows_affected);

/* Execute a prepared statement as a batch inside a single transaction.
 * params is a flat row-major array of row_count * params_per_row values.
 * On error the transaction is rolled back. */
int32_t     stoolap_stmt_exec_batch(StoolapDB* db,
                                    const StoolapStmt* stmt,
                                    const StoolapValue* params,
                                    int32_t params_per_row,
                                    int32_t row_count,
                                    int64_t* total_affected);

int32_t     stoolap_stmt_query(StoolapStmt* stmt,
                               const StoolapValue* params,
                               int32_t params_len,
                               StoolapRows** out_rows);

const char* stoolap_stmt_sql(const StoolapStmt* stmt);
void        stoolap_stmt_finalize(StoolapStmt* stmt);
const char* stoolap_stmt_errmsg(const StoolapStmt* stmt);

/* ------------------------------------------------------------------ *
 *  Transactions
 * ------------------------------------------------------------------ */

int32_t stoolap_begin(StoolapDB* db, StoolapTx** out_tx);
int32_t stoolap_begin_with_isolation(StoolapDB* db, int32_t isolation, StoolapTx** out_tx);

int32_t stoolap_tx_exec(StoolapTx* tx,
                        const char* sql,
                        int64_t* rows_affected);

int32_t stoolap_tx_exec_params(StoolapTx* tx,
                               const char* sql,
                               const StoolapValue* params,
                               int32_t params_len,
                               int64_t* rows_affected);

int32_t stoolap_tx_query(StoolapTx* tx,
                         const char* sql,
                         StoolapRows** out_rows);

int32_t stoolap_tx_query_params(StoolapTx* tx,
                                const char* sql,
                                const StoolapValue* params,
                                int32_t params_len,
                                StoolapRows** out_rows);

int32_t stoolap_tx_stmt_exec(StoolapTx* tx,
                             StoolapStmt* stmt,
                             const StoolapValue* params,
                             int32_t params_len,
                             int64_t* rows_affected);

int32_t stoolap_tx_stmt_query(StoolapTx* tx,
                              StoolapStmt* stmt,
                              const StoolapValue* params,
                              int32_t params_len,
                              StoolapRows** out_rows);

int32_t stoolap_tx_commit(StoolapTx* tx);
int32_t stoolap_tx_rollback(StoolapTx* tx);

const char* stoolap_tx_errmsg(const StoolapTx* tx);

/* ------------------------------------------------------------------ *
 *  Cursor: iterate result sets one row at a time (the SQLite pattern)
 * ------------------------------------------------------------------ */

/* Returns STOOLAP_ROW if a row is ready, STOOLAP_DONE if exhausted,
 * STOOLAP_ERROR on failure (read stoolap_rows_errmsg). */
int32_t        stoolap_rows_next(StoolapRows* rows);

/* Free the result set. Always call exactly once per StoolapRows. */
void           stoolap_rows_close(StoolapRows* rows);

int32_t        stoolap_rows_column_count(const StoolapRows* rows);

/* Returns a pointer owned by the rows handle, valid until rows_close. */
const char*    stoolap_rows_column_name(const StoolapRows* rows, int32_t index);

/* STOOLAP_TYPE_*; valid only after a successful stoolap_rows_next. */
int32_t        stoolap_rows_column_type(const StoolapRows* rows, int32_t index);
int32_t        stoolap_rows_column_is_null(const StoolapRows* rows, int32_t index);

int64_t        stoolap_rows_column_int64(const StoolapRows* rows, int32_t index);
double         stoolap_rows_column_double(const StoolapRows* rows, int32_t index);
int32_t        stoolap_rows_column_bool(const StoolapRows* rows, int32_t index);
int64_t        stoolap_rows_column_timestamp(const StoolapRows* rows, int32_t index);

/* Pointer is owned by the rows handle, valid until the next stoolap_rows_next.
 * If `out_len` is non-NULL it receives the byte length (excluding trailing NUL).
 * Returns NULL when the column is NULL. */
const char*    stoolap_rows_column_text(StoolapRows* rows, int32_t index, int64_t* out_len);

/* Vector blobs (packed f32). Pointer is valid until the next stoolap_rows_next. */
const uint8_t* stoolap_rows_column_blob(const StoolapRows* rows, int32_t index, int64_t* out_len);

int64_t        stoolap_rows_affected(const StoolapRows* rows);
const char*    stoolap_rows_errmsg(const StoolapRows* rows);

/* Optional bulk path: dump every remaining row into a heap-allocated
 * binary buffer. Caller must free with stoolap_buffer_free. The Swift
 * driver does NOT use this path — the cursor functions above are
 * faster for typical workloads. */
int32_t        stoolap_rows_fetch_all(StoolapRows* rows, uint8_t** out_buf, int64_t* out_len);
void           stoolap_buffer_free(uint8_t* buf, int64_t len);

#ifdef __cplusplus
}
#endif

#endif /* STOOLAP_H */
