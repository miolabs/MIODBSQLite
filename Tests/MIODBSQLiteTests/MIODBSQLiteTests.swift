//
//  MIODBSQLiteTests.swift
//  MIODBSQLiteTests
//
//  Created by Javier Segura Perez on 25/07/2026.
//  Copyright © 2026 Javier Segura Perez. All rights reserved.
//

import XCTest
import MIODB
@testable import MIODBSQLite

final class MIODBSQLiteTests: XCTestCase
{
    var db: MIODBSQLite!

    override func setUpWithError() throws {
        db = MIODBSQLite()
        try db.connect( ":memory:" )
        try db.executeQuery( """
            CREATE TABLE "product" (
                "id"       UUID PRIMARY KEY,
                "name"     TEXT,
                "price"    DECIMAL,
                "quantity" INTEGER,
                "enabled"  BOOLEAN,
                "created"  TIMESTAMP,
                "info"     JSON,
                "payload"  BLOB
            )
            """ )
    }

    override func tearDown() {
        db.disconnect()
        db = nil
    }

    // MARK: - Connection

    func testConnectionFactory () throws {
        let conn = MDBSQLiteConnection()
        let created = try conn.create( ":memory:" )
        XCTAssertTrue( created is MIODBSQLite )
        XCTAssertNil( created as? MDBCredentials )
        XCTAssertNil( created as? MDBSchemes )
        created.disconnect()
    }

    func testPragmasApplied () throws {
        let fk = try db.executeQuery( "PRAGMA foreign_keys" )
        XCTAssertEqual( fk[ 0 ][ 0 ] as? Int, 1 )
    }

    // MARK: - CRUD through MDBQuery

    func testInsertSelectRoundtrip () throws {
        let id = UUID()
        let created = Date( timeIntervalSince1970: 1_753_000_000 ) // whole seconds
        try db.execute( MDBQuery( "product" ).insert( [
            "id"      : id,
            "name"    : "Beer",
            "price"   : Decimal( string: "3.50" )!,
            "quantity": 24,
            "enabled" : true,
            "created" : created
        ] ) )

        let rs = try db.execute( MDBQuery( "product" ).select() )
        XCTAssertEqual( rs.rowCount, 1 )

        let row = rs[ 0 ]
        XCTAssertEqual( try row.uuidValue( "id" ), id )
        XCTAssertEqual( try row.stringValue( "name" ), "Beer" )
        XCTAssertEqual( try row.decimalValue( "price" ), Decimal( string: "3.50" )! )
        XCTAssertEqual( try row.intValue( "quantity" ), 24 )
        XCTAssertEqual( try row.boolValue( "enabled" ), true )
        XCTAssertEqual( try row.dateValue( "created" ), created )
        XCTAssertTrue( row.isNull( "info" ) )
    }

    func testUpdateAndAffectedRows () throws {
        try db.execute( MDBQuery( "product" ).insert( [ "id": UUID(), "name": "A", "quantity": 1 ] ) )
        try db.execute( MDBQuery( "product" ).insert( [ "id": UUID(), "name": "B", "quantity": 1 ] ) )

        let update = try db.execute( MDBQuery( "product" ).update( [ "quantity": 5 ] ) )
        XCTAssertEqual( update.affectedRowCount, 2 )

        let select = try db.execute( MDBQuery( "product" ).select() )
        XCTAssertEqual( select.affectedRowCount, 0 )
        XCTAssertEqual( select[ 0 ].int( "quantity" ), 5 )
    }

    func testDelete () throws {
        try db.execute( MDBQuery( "product" ).insert( [ "id": UUID(), "name": "A" ] ) )
        let del = try db.execute( MDBQuery( "product" ).delete().andWhere( "name", .EQ, "A" ) )
        XCTAssertEqual( del.affectedRowCount, 1 )
        XCTAssertEqual( try db.execute( MDBQuery( "product" ).select() ).rowCount, 0 )
    }

    func testMultiInsert () throws {
        let values: [[String:Any?]] = (0..<50).map { [ "id": UUID(), "name": "p\($0)", "quantity": $0 ] }
        try db.execute( MDBQuery( "product" ).insert( values ) )

        let rs = try db.execute( MDBQuery( "product" ).select() )
        XCTAssertEqual( rs.rowCount, 50 )
    }

    func testUpsert () throws {
        let id = UUID()
        try db.execute( MDBQuery( "product" ).upsert( [ "id": id, "name": "old", "quantity": 1 ], "id" ) )
        try db.execute( MDBQuery( "product" ).upsert( [ "id": id, "name": "new", "quantity": 2 ], "id" ) )

        let rs = try db.execute( MDBQuery( "product" ).select() )
        XCTAssertEqual( rs.rowCount, 1 )
        XCTAssertEqual( rs[ 0 ].string( "name" ), "new" )
    }

    func testReturning () throws {
        let id = UUID()
        let rs = try db.execute( MDBQuery( "product" ).insert( [ "id": id, "name": "A" ] ).returning( "id", "name" ) )
        XCTAssertEqual( rs.rowCount, 1 )
        XCTAssertEqual( try rs[ 0 ].uuidValue( "id" ), id )
        XCTAssertEqual( rs[ 0 ].string( "name" ), "A" )
    }

    // MARK: - NULL handling

    func testNullValues () throws {
        try db.execute( MDBQuery( "product" ).insert( [ "id": UUID(), "name": nil, "info": NSNull() ] ) )

        let row = try db.execute( MDBQuery( "product" ).select() )[ 0 ]
        XCTAssertTrue( row.isNull( "name" ) )
        XCTAssertTrue( row[ "name" ] is NSNull )
        XCTAssertNil( row.string( "name" ) )
    }

    // MARK: - Type conversion

    func testJSONConversion () throws {
        try db.executeQuery( "INSERT INTO \"product\" (\"id\", \"info\") VALUES ('\(UUID().uuidString)', '{\"a\": [1, 2]}')" )
        let row = try db.execute( MDBQuery( "product" ).select() )[ 0 ]
        let info = row[ "info" ] as? [String:Any]
        XCTAssertEqual( info?[ "a" ] as? [Int], [ 1, 2 ] )
    }

    func testIntegerStoredDecimal () throws {
        // SQLite stores integral NUMERIC values as INTEGER; the declared type
        // must still surface them as Decimal.
        try db.executeQuery( "INSERT INTO \"product\" (\"id\", \"price\") VALUES ('\(UUID().uuidString)', 5)" )
        let row = try db.execute( MDBQuery( "product" ).select() )[ 0 ]
        XCTAssertEqual( row.decimal( "price" ), Decimal( 5 ) )
    }

    func testBlob () throws {
        let payload = Data( [0x00, 0x01, 0xFF] )
        try db.executeQuery( "INSERT INTO \"product\" (\"id\", \"payload\") VALUES ('\(UUID().uuidString)', x'0001FF')" )
        let row = try db.execute( MDBQuery( "product" ).select() )[ 0 ]
        XCTAssertEqual( row[ "payload" ] as? Data, payload )
    }

    func testUndeclaredColumnFallsBackToStorageClass () throws {
        let rs = try db.executeQuery( "SELECT 1 AS n, 'x' AS s, 1.5 AS r" )
        XCTAssertEqual( rs[ 0 ][ "n" ] as? Int, 1 )
        XCTAssertEqual( rs[ 0 ][ "s" ] as? String, "x" )
        XCTAssertEqual( rs[ 0 ][ "r" ] as? Double, 1.5 )
    }

    // MARK: - Executor mechanics

    func testMultiStatementQuery () throws {
        let rs = try db.executeQuery( "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1); SELECT a FROM t" )
        XCTAssertEqual( rs.rowCount, 1 )
        XCTAssertEqual( rs[ 0 ][ "a" ] as? Int, 1 )
    }

    func testSyntaxErrorThrows () {
        XCTAssertThrowsError( try db.executeQuery( "SELEC nonsense" ) ) { error in
            XCTAssertTrue( error is MIODBSQLiteError )
        }
    }

    func testFileDatabasePersists () throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent( "miodbsqlite-test-\(UUID().uuidString).sqlite" ).path
        defer { try? FileManager.default.removeItem( atPath: path ) }

        let file_db = MIODBSQLite()
        try file_db.connect( path )
        try file_db.executeQuery( "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (7)" )
        file_db.disconnect()

        let again = MIODBSQLite()
        try again.connect( path )
        let rs = try again.executeQuery( "SELECT a FROM t" )
        XCTAssertEqual( rs[ 0 ][ "a" ] as? Int, 7 )
        again.disconnect()
    }

    // MARK: - Dialect adaptation

    func testSelectForUpdateIsStripped () throws {
        try db.execute( MDBQuery( "product" ).insert( [ "id": UUID(), "name": "A" ] ) )
        let rs = try db.execute( MDBQuery( "product" ).select_for_update() )
        XCTAssertEqual( rs.rowCount, 1 )
    }

    func testILikeIsRewritten () throws {
        try db.execute( MDBQuery( "product" ).insert( [ "id": UUID(), "name": "Hello World" ] ) )
        let rs = try db.execute( MDBQuery( "product" ).select().andWhere( "name", .ILIKE, "hello%" ) )
        XCTAssertEqual( rs.rowCount, 1 )
    }
}
