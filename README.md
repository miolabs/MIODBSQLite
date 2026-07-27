# MIODBSQLite

SQLite backend for [MIODB](https://github.com/miolabs/MIODB) — the full MIODB query builder and typed result-set API over an embedded database file. No server, no credentials, no schemas: the whole configuration is `database` — the file path, or `":memory:"`.

```swift
import MIODB
import MIODBSQLite

let conn = MDBSQLiteConnection( database: "/data/shop.sqlite" )
let db = try conn.create()

try db.execute( MDBQuery( "product" ).insert( [
    "id": UUID(), "name": "Beer", "price": Decimal( string: "3.50" )!
] ) )

let rows = try db.execute( MDBQuery( "product" ).select().orderBy( "name" ) )
for row in rows {
    print( row.string( "name" ) ?? "-", row.decimal( "price" ) ?? 0 )
}
```

The backend conforms to neither `MDBCredentials` nor `MDBSchemes`. Multi-tenant setups map one tenant to one database file, selected with `create(to_db:)` / `connect(to_db:)`.

## Installation

```swift
dependencies: [
    .package( url: "https://github.com/miolabs/MIODBSQLite.git", from: "1.0.0" ),
]
```

On Apple platforms the SDK ships `sqlite3`; on Linux install `libsqlite3-dev`.

## Example

A runnable tour of the API (CRUD, typed rows, upsert, RETURNING, JSON, transactions, multi-row inserts) lives in [Sources/Example/main.swift](Sources/Example/main.swift):

```bash
swift run Example
```

## Type mapping

SQLite is dynamically typed (INTEGER, REAL, TEXT, BLOB, NULL); the strict MIODB contract — every column maps to exactly one Swift type — comes from the **declared column type**:

| Declared type contains | Swift type |
|---|---|
| `BOOL` | `Bool` |
| `TIMESTAMP`, `DATETIME`, `DATE` | `Date` |
| `UUID` | `UUID` |
| `NUMERIC`, `DECIMAL`, `MONEY` | `Decimal` |
| `JSON` | `JSONSerialization` output (`[String:Any]`, `[Any]`, ...) |
| `BLOB` (storage class) | `Data` |
| *(no declared type)* | storage class: `Int`, `Double`, `String`, `Data` |

A value that fails its declared-type conversion throws `MDBError.conversionFailed` instead of degrading to the raw string.

## Behavior notes

- **Result sets are materialized.** Unlike the PostgreSQL backend (lazy view over a `PGresult`), an open `sqlite3_stmt` holds database locks, so rows are copied into typed storage at execute time and the statement is finalized immediately. Cell values are still converted lazily on access.
- **Dialect**: queries built with `MDBQuery` render through `MDBSQLiteDialect` — `FOR UPDATE` is dropped (SQLite writes lock the whole file), `ILIKE` renders as `LIKE` (case-insensitive for ASCII, matching ILIKE semantics for ASCII text), and multi-row `update` uses the SQLite `VALUES` form. `DISTINCT ON` and the JSON operators throw `MDBError.unsupported`. Raw SQL strings passed to `executeQuery(_:)` are executed untouched — portability of raw fragments is the caller's responsibility.
- **Pragmas on connect**: `busy_timeout` (configurable via `MDB_SQLITE_BUSY_TIMEOUT`, ms, default 5000), `journal_mode=WAL`, `foreign_keys=ON`.
- **Multi-statement strings** (`stmt1; stmt2`) execute like libpq's `PQexec`: the result of the last statement is returned.
- **`affectedRowCount`** is reported for writes only; read-only statements report 0 even after previous writes on the same connection.

## Requirements

- macOS 12+ with any Xcode SDK (ships `sqlite3`), or Linux with `libsqlite3-dev`.
- SQLite ≥ 3.35 for `RETURNING` (2021; any current macOS or Ubuntu qualifies).
