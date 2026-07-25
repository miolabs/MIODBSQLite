//
//  MIODBSQLite.swift
//  MIODBSQLite
//
//  Created by Javier Segura Perez on 25/07/2026.
//  Copyright © 2026 Javier Segura Perez. All rights reserved.
//

import Foundation
import MIOCore
import MIODB
@_implementationOnly import CSQLite
import MIOCoreLogger


public enum MIODBSQLiteError: Error {
    case fatalError( _ code:Int32, _ msg: String )
}

extension MIODBSQLiteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .fatalError(code, msg):
            return "Fatal error. Code: \(code) Message: \"\(msg)\"."
        }
    }
}

/// SQLite backend of MIODB. Embedded: the whole configuration is `database`
/// (the file path, or ":memory:"). No credentials, no schemas — the class
/// conforms to neither `MDBCredentials` nor `MDBSchemes`. One venue = one
/// database file, selected with `connect(to_db:)` / `create(to_db:)`.
open class MIODBSQLite: MIODB
{
    var _connection: OpaquePointer? // sqlite3*

    deinit { disconnect() }

    open override func connect( _ to_db: String? = nil ) throws
    {
        let path = to_db ?? database ?? ":memory:"

        Log.debug( "ID: \(identifier). Connecting to SQLITE Database. Path: \(path)" )

        var handle: OpaquePointer? = nil
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2( path, &handle, flags, nil )
        guard rc == SQLITE_OK, handle != nil else {
            let msg = handle != nil ? String( cString: sqlite3_errmsg( handle ) ) : "out of memory"
            if handle != nil { sqlite3_close_v2( handle ) }
            Log.error( "ID: \(identifier). Could not connect to SQLITE Database. Path: \(path)" )
            throw MIODBSQLiteError.fatalError( rc, "Could not connect to SQLITE Database. \(msg)" )
        }

        _connection = handle
        database = path
        connectionString = path

        try super.connect( to_db )

        // busy_timeout: bound how long a statement waits on a locked database
        // before failing with SQLITE_BUSY, the analog of the Postgres
        // statement_timeout. Configurable via MDB_SQLITE_BUSY_TIMEOUT (ms).
        // WAL keeps readers unblocked by the single writer; per-file journals
        // are what makes one database per venue isolate lock contention.
        let busy_timeout = MCEnvironmentVar( "MDB_SQLITE_BUSY_TIMEOUT" ) ?? "5000"
        _ = try? executeQuery( "PRAGMA busy_timeout = \(busy_timeout); PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON" )
    }

    open override func disconnect() {
        if _connection != nil {
            sqlite3_close_v2( _connection )
            _connection = nil
            Log.debug( "ID: \(identifier). Disconnecting from SQLITE Database. Path: \(database ?? "-")" )
            super.disconnect()
        }
    }

    /// Executes one or more ';'-separated statements and returns the result
    /// of the last one, mirroring the libpq PQexec behavior the Postgres
    /// backend relies on. Rows are materialized into typed storage and the
    /// statement is finalized before returning: unlike a PGresult, an open
    /// sqlite3_stmt holds database locks, so nothing may outlive this call.
    /// Cell values are still converted lazily on access.
    @discardableResult open override func executeQuery( _ query:String ) throws -> MDBSQLiteResultSet {
        queryWillExecute()
        defer { queryDidExecute() }

        guard let conn = _connection else {
            throw MIODBSQLiteError.fatalError( -1, "Connection is nil\n" + query )
        }

        Log.trace( "ID: \(identifier). QUERY: \(query)" )

        let sql = adaptToDialect( query )
        var resultSet: MDBSQLiteResultSet? = nil

        try sql.withCString { ( cstr: UnsafePointer<CChar> ) in
            var cursor: UnsafePointer<CChar>? = cstr

            while let current = cursor, current.pointee != 0 {
                var stmt: OpaquePointer? = nil
                var tail: UnsafePointer<CChar>? = nil

                let rc = sqlite3_prepare_v2( conn, current, -1, &stmt, &tail )
                guard rc == SQLITE_OK else {
                    let msg = String( cString: sqlite3_errmsg( conn ) ) + "\n" + query
                    Log.trace( "ID: \(identifier). \(msg)" )
                    throw MIODBSQLiteError.fatalError( sqlite3_extended_errcode( conn ), msg )
                }

                guard tail != current else { break } // no progress, avoid spinning
                cursor = tail

                // nil stmt with SQLITE_OK: whitespace or comment-only chunk.
                guard let s = stmt else { continue }
                resultSet = try run( statement: s, connection: conn, query: query )
            }
        }

        return resultSet ?? MDBSQLiteResultSet( columns: [], declaredTypes: [], rows: [], affectedRowCount: 0, db: self )
    }

    /// Steps a prepared statement to completion, collecting every row into
    /// typed storage, and finalizes it.
    private func run ( statement stmt: OpaquePointer, connection conn: OpaquePointer, query: String ) throws -> MDBSQLiteResultSet
    {
        let col_count = Int( sqlite3_column_count( stmt ) )
        var cols = [String]() ; cols.reserveCapacity( col_count )
        var decls = [String?]() ; decls.reserveCapacity( col_count )

        for col in 0..<Int32( col_count ) {
            cols.append( String( cString: sqlite3_column_name( stmt, col ) ) )
            decls.append( sqlite3_column_decltype( stmt, col ).map { String( cString: $0 ).uppercased() } )
        }

        var rows = [[MDBSQLiteValue]]()

        step: while true {
            switch sqlite3_step( stmt ) {
            case SQLITE_ROW:
                var row = [MDBSQLiteValue]() ; row.reserveCapacity( col_count )
                for col in 0..<Int32( col_count ) {
                    switch sqlite3_column_type( stmt, col ) {
                    case SQLITE_INTEGER: row.append( .int( sqlite3_column_int64( stmt, col ) ) )
                    case SQLITE_FLOAT  : row.append( .real( sqlite3_column_double( stmt, col ) ) )
                    case SQLITE_TEXT   : row.append( .text( String( cString: sqlite3_column_text( stmt, col ) ) ) )
                    case SQLITE_BLOB   :
                        let len = Int( sqlite3_column_bytes( stmt, col ) )
                        if let bytes = sqlite3_column_blob( stmt, col ), len > 0 { row.append( .blob( Data( bytes: bytes, count: len ) ) ) }
                        else { row.append( .blob( Data() ) ) }
                    default            : row.append( .null )
                    }
                }
                rows.append( row )

            case SQLITE_DONE: break step

            default:
                let msg = String( cString: sqlite3_errmsg( conn ) ) + "\n" + query
                let code = sqlite3_extended_errcode( conn )
                sqlite3_finalize( stmt )
                Log.trace( "ID: \(identifier). \(msg)" )
                throw MIODBSQLiteError.fatalError( code, msg )
            }
        }

        // Read-only statements (SELECT) report 0 affected rows; sqlite3_changes
        // would otherwise leak the count of a previous write on the connection.
        let affected = sqlite3_stmt_readonly( stmt ) != 0 ? 0 : Int( sqlite3_changes( conn ) )
        sqlite3_finalize( stmt )

        return MDBSQLiteResultSet( columns: cols, declaredTypes: decls, rows: rows, affectedRowCount: affected, db: self )
    }

    /// MDBQuery generates Postgres-flavored SQL. Two constructs need adapting:
    /// - `FOR UPDATE` is a parse error in SQLite and meaningless there (writes
    ///   lock the whole database), so a trailing clause is dropped.
    /// - `ILIKE` is not SQLite syntax; plain LIKE is already case-insensitive
    ///   for ASCII, which matches ILIKE semantics for ASCII text.
    func adaptToDialect ( _ query: String ) -> String {
        var sql = query
        if sql.hasSuffix( " FOR UPDATE" ) { sql = String( sql.dropLast( " FOR UPDATE".count ) ) }
        if sql.contains( " ILIKE " ) { sql = sql.replacingOccurrences( of: " ILIKE ", with: " LIKE " ) }
        return sql
    }

    /// Converts a cell from its SQLite storage class to the Swift type its
    /// declared column type implies. SQLite is dynamically typed (INTEGER,
    /// REAL, TEXT, BLOB, NULL), so the strict MIODB contract — every column
    /// maps to exactly one Swift type — comes from the declared type instead:
    /// BOOLEAN → Bool, TIMESTAMP/DATETIME/DATE → Date, UUID → UUID,
    /// NUMERIC/DECIMAL → Decimal, JSON → JSONSerialization. An unparseable
    /// value throws instead of degrading to the raw string.
    func convert ( value: MDBSQLiteValue, declaredType decl: String? ) throws -> Any
    {
        func conversionFailed ( _ typeName: String, _ str: String ) -> MDBError {
            Log.error( "ID: \(identifier). Value \"\(str)\" can't be converted to \(typeName). Declared type: \(decl ?? "-")" )
            return MDBError.conversionFailed( typeName, str )
        }

        switch value {
        case .null: return NSNull()

        case .int( let v ):
            if let d = decl {
                if d.contains( "BOOL" ) { return v != 0 }
                if d.contains( "NUMERIC" ) || d.contains( "DECIMAL" ) || d.contains( "MONEY" ) { return Decimal( v ) }
            }
            return Int( v )

        case .real( let v ):
            if let d = decl, d.contains( "NUMERIC" ) || d.contains( "DECIMAL" ) || d.contains( "MONEY" ) {
                // through the string to avoid the binary-double dirt a direct
                // Double→Decimal conversion introduces
                return Decimal( string: "\(v)" ) ?? Decimal( v )
            }
            return v

        case .text( let str ):
            guard let d = decl else { return str }

            if d.contains( "TIMESTAMP" ) || d.contains( "DATETIME" ) || d.contains( "DATE" ) {
                if let date = MDBSQLParseTimestamp( str ) { return date }
                guard let date = MIOCoreDate( fromString: str ) else { throw conversionFailed( "Date", str ) }
                return date
            }
            if d.contains( "UUID" ) {
                guard let u = UUID( uuidString: str ) else { throw conversionFailed( "UUID", str ) }
                return u
            }
            if d.contains( "JSON" ) {
                return try JSONSerialization.jsonObject( with: str.data( using: .utf8 )!, options: [.allowFragments] )
            }
            if d.contains( "NUMERIC" ) || d.contains( "DECIMAL" ) || d.contains( "MONEY" ) {
                if str == "NaN" { return Decimal.nan }
                guard let dec = Decimal( string: str ) else { throw conversionFailed( "Decimal", str ) }
                return dec
            }
            if d.contains( "BOOL" ) {
                switch str.lowercased() {
                case "t", "true", "1" : return true
                case "f", "false", "0": return false
                default: throw conversionFailed( "Bool", str )
                }
            }
            return str

        case .blob( let data ): return data
        }
    }
}
