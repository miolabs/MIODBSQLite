//
//  main.swift
//  MIODBSQLite Example
//
//  A runnable tour of MIODB over the SQLite backend: `swift run Example`.
//  Uses an in-memory database, so it needs no setup and leaves no files.
//

import Foundation
import MIODB
import MIODBSQLite

// MARK: - Connect

// The factory pattern used by server code. For a file-backed database pass
// the path instead of ":memory:" — see the persistence section below.
let connection = MDBSQLiteConnection( database: ":memory:" )
let db = try connection.create()

print( "== Schema ==" )

// Declared column types drive the Swift type of every cell (BOOLEAN → Bool,
// TIMESTAMP → Date, UUID → UUID, DECIMAL → Decimal, JSON → dictionaries).
try db.executeQuery( """
    CREATE TABLE "product" (
        "id"       UUID PRIMARY KEY,
        "name"     TEXT NOT NULL,
        "price"    DECIMAL,
        "stock"    INTEGER DEFAULT 0,
        "enabled"  BOOLEAN DEFAULT TRUE,
        "created"  TIMESTAMP,
        "info"     JSON
    )
    """ )
print( "table \"product\" created\n" )

// MARK: - INSERT

print( "== INSERT ==" )

let beerID = UUID()
try db.execute( MDBQuery( "product" ).insert( [
    "id"     : beerID,
    "name"   : "Beer",
    "price"  : Decimal( string: "3.50" )!,
    "stock"  : 24,
    "created": Date(),
    "info"   : [ "origin": "Galicia", "tags": [ "lager", "draft" ] ]
] ) )

// Multi-row insert: one statement, all rows must share the same keys.
try db.execute( MDBQuery( "product" ).insert( [
    [ "id": UUID(), "name": "Wine",  "price": Decimal( string: "12.00" )!, "stock": 6 ],
    [ "id": UUID(), "name": "Cider", "price": Decimal( string: "4.25" )!,  "stock": 0 ],
    [ "id": UUID(), "name": "Water", "price": Decimal( string: "1.10" )!,  "stock": 120 ],
] ) )

// RETURNING hands back the inserted row.
let inserted = try db.execute( MDBQuery( "product" )
    .insert( [ "id": UUID(), "name": "Juice", "price": Decimal( string: "2.75" )! ] )
    .returning( "id", "name" ) )
print( "inserted:", inserted[ 0 ].string( "name" )!, inserted[ 0 ].uuid( "id" )! )
print()

// MARK: - SELECT and typed rows

print( "== SELECT ==" )

let catalog = try db.execute( MDBQuery( "product" )
    .select( "id", "name", "price", "stock" )
    .andWhere( "price", .GT, 1 )
    .orderBy( "name" ) )

// MDBResultSet is a RandomAccessCollection of MDBRow views. Cells convert
// to their Swift type only when accessed.
for row in catalog {
    // Optional accessors: nil on missing column, SQL NULL or bad conversion.
    let name  = row.string( "name" ) ?? "-"
    let price = row.decimal( "price" ) ?? 0
    let stock = row.int( "stock" ) ?? 0
    print( "  \(name)  \(price) €  (\(stock) in stock)" )
}

// Throwing accessors say WHY a value is unavailable.
let first = catalog[ 0 ]
let id: UUID = try first.uuidValue( "id" )
print( "first id:", id )

do {
    _ = try first.decimalValue( "nope" )
}
catch {
    print( "throwing accessor:", error.localizedDescription )
}
print()

// MARK: - WHERE combinations

print( "== WHERE ==" )

// WHERE "enabled" = TRUE AND ("stock" > 0 OR "price" < 2)
let available = try db.execute( MDBQuery( "product" ).select( "name" )
    .andWhere( "enabled", true )
    .beginGroup()
        .andWhere( "stock", .GT, 0 )
        .orWhere( "price", .LT, 2 )
    .endGroup()
    .orderBy( "name" ) )
print( "available:", available.map { $0.string( "name" )! }.joined( separator: ", " ) )

// IN lists and pattern matching (ILIKE is rewritten to LIKE by the backend).
let matches = try db.execute( MDBQuery( "product" ).select( "name" )
    .andWhereIN( "name", [ "Beer", "Wine", "Gin" ] )
    .orWhere( "name", .ILIKE, "wat%" ) )
print( "matches:", matches.map { $0.string( "name" )! }.joined( separator: ", " ) )
print()

// MARK: - UPDATE / UPSERT / DELETE

print( "== UPDATE / UPSERT / DELETE ==" )

let update = try db.execute( MDBQuery( "product" )
    .update( [ "stock": 12, "enabled": false ] )
    .andWhere( "id", beerID ) )
print( "updated rows:", update.affectedRowCount )

// UPSERT: insert, or update on conflict.
try db.execute( MDBQuery( "product" )
    .upsert( [ "id": beerID, "name": "Beer", "price": Decimal( string: "3.75" )!, "stock": 36 ], "id" ) )
let beer = try db.execute( MDBQuery( "product" ).select().andWhere( "id", beerID ) )[ 0 ]
print( "after upsert:", beer.string( "name" )!, beer.decimal( "price" )!, "stock", beer.int( "stock" )! )

let deleted = try db.execute( MDBQuery( "product" ).delete().andWhere( "name", .EQ, "Cider" ) )
print( "deleted rows:", deleted.affectedRowCount )
print()

// MARK: - JSON columns

print( "== JSON ==" )

if let info = beer[ "info" ] as? [String:Any] {
    print( "origin:", info[ "origin" ] as? String ?? "-",
           "tags:", info[ "tags" ] as? [String] ?? [] )
}
print()

// MARK: - Transactions

print( "== Transaction ==" )

try db.executeQuery( MDBQuery.beginTransactionStament() )
do {
    try db.execute( MDBQuery( "product" ).update( [ "stock": 0 ] ).andWhere( "name", "Water" ) )
    try db.executeQuery( "ROLLBACK" ) // change of heart: undo it
}
let water = try db.execute( MDBQuery( "product" ).select( "stock" ).andWhere( "name", "Water" ) )
print( "water stock after rollback:", water[ 0 ].int( "stock" )! )
print()

// MARK: - Legacy dictionary shape

print( "== Dictionaries ==" )

// Materialize everything upfront when handing rows to untyped code.
let dicts = try db.execute( MDBQuery( "product" ).select( "name", "price" ).limit( 2 ) ).dictionaries()
print( dicts )
print()

// MARK: - File persistence

print( "== File persistence ==" )

let path = FileManager.default.temporaryDirectory
    .appendingPathComponent( "miodbsqlite-example.sqlite" ).path
defer { try? FileManager.default.removeItem( atPath: path ) }

let fileDB = try MDBSQLiteConnection( database: path ).create()
try fileDB.executeQuery( "CREATE TABLE IF NOT EXISTS counter (n INTEGER)" )
try fileDB.executeQuery( "INSERT INTO counter VALUES (7)" )
fileDB.disconnect()

let again = try MDBSQLiteConnection( database: path ).create()
let n = try again.executeQuery( "SELECT n FROM counter" )[ 0 ].int( "n" )!
print( "read back from \(path): \(n)" )
again.disconnect()

db.disconnect()
print( "\ndone." )
