# MIODBSQLite

SQLite backend for [MIODB](https://github.com/miolabs/MIODB). Embedded: the whole configuration is `database` — the file path, or `":memory:"`. No credentials, no schemas; the backend conforms to neither `MDBCredentials` nor `MDBSchemes`. One venue = one database file, selected with `connect(to_db:)` / `create(to_db:)`.

```swift
let conn = MDBSQLiteConnection( database: "/data/venue_a.sqlite" )
let db = try conn.create( nil )
let rows = try db.execute( MDBQuery( "product" ).select() )
```

## Behavior notes

- **Result sets are materialized.** Unlike the PostgreSQL backend (lazy view over a `PGresult`), an open `sqlite3_stmt` holds database locks, so rows are copied into typed storage at execute time and the statement is finalized immediately. Cell values are still converted lazily on access.
- **Type mapping is driven by the declared column type**: `BOOLEAN` → `Bool`, `TIMESTAMP`/`DATETIME`/`DATE` → `Date`, `UUID` → `UUID`, `NUMERIC`/`DECIMAL` → `Decimal`, `JSON` → `JSONSerialization` output, `BLOB` → `Data`. Columns without a declared type surface their SQLite storage class (`Int`, `Double`, `String`, `Data`).
- **Dialect adaptation**: a trailing `FOR UPDATE` is stripped (SQLite writes lock the whole file) and `ILIKE` is rewritten to `LIKE` (case-insensitive for ASCII, matching ILIKE semantics for ASCII text). `::jsonb` casts are not supported.
- **Pragmas on connect**: `busy_timeout` (configurable via `MDB_SQLITE_BUSY_TIMEOUT`, ms, default 5000), `journal_mode=WAL`, `foreign_keys=ON`.
- **Multi-statement strings** (`stmt1; stmt2`) execute like libpq's `PQexec`: the result of the last statement is returned.

## Requirements

- macOS 12+ with any Xcode SDK (ships `sqlite3`), or Linux with `libsqlite3-dev`.
- SQLite ≥ 3.35 for `RETURNING` (2021; any current macOS or Ubuntu qualifies).
