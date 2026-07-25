//
//  MDBSQLiteResultSet.swift
//  MIODBSQLite
//
//  Created by Javier Segura Perez on 25/07/2026.
//  Copyright © 2026 Javier Segura Perez. All rights reserved.
//

import Foundation
import MIODB

/// A cell in its SQLite storage class, copied out of the statement without
/// any type conversion.
public enum MDBSQLiteValue
{
    case null
    case int( Int64 )
    case real( Double )
    case text( String )
    case blob( Data )
}

/// SQLite backend of `MDBResultSet`.
///
/// Unlike the PostgreSQL result set — a lazy view over a PGresult that is
/// independent of the connection socket — an open sqlite3_stmt holds database
/// locks and blocks connection reuse. Rows are therefore materialized into
/// typed storage at execute time and the statement is finalized immediately.
/// The lazy part is preserved where it matters: converting a cell to its
/// Swift value (declared-type driven) happens only when it is accessed.
public final class MDBSQLiteResultSet : MDBResultSet
{
    let declaredTypes: [String?]
    let rows: [[MDBSQLiteValue]]
    let db: MIODBSQLite

    init ( columns: [String], declaredTypes: [String?], rows: [[MDBSQLiteValue]], affectedRowCount: Int, db: MIODBSQLite )
    {
        self.declaredTypes = declaredTypes
        self.rows = rows
        self.db = db
        super.init( columns: columns, rowCount: rows.count, affectedRowCount: affectedRowCount )
    }

    // MARK: - Cell primitives

    public override func isNull ( row: Int, col: Int ) -> Bool {
        if case .null = rows[ row ][ col ] { return true }
        return false
    }

    public override func rawValue ( row: Int, col: Int ) -> String? {
        switch rows[ row ][ col ] {
        case .null            : return nil
        case .int( let v )    : return String( v )
        case .real( let v )   : return String( v )
        case .text( let s )   : return s
        case .blob( let data ): return data.base64EncodedString()
        }
    }

    /// Throws only for values that fail their declared-type conversion.
    public override func value ( row: Int, col: Int ) throws -> Any? {
        return try db.convert( value: rows[ row ][ col ], declaredType: declaredTypes[ col ] )
    }

    /// Integer fast path: reads the typed storage directly, no boxing.
    public override func intValue ( row: Int, col: Int ) -> Int? {
        switch rows[ row ][ col ] {
        case .int( let v ) : return Int( v )
        case .real( let v ): return Int( exactly: v.rounded() )
        case .text( let s ): return Int( s )
        default            : return nil
        }
    }

    public override func boolValue ( row: Int, col: Int ) -> Bool? {
        switch rows[ row ][ col ] {
        case .int( let v ) : return v != 0
        case .text( let s ):
            switch s.lowercased() {
            case "t", "true", "1" : return true
            case "f", "false", "0": return false
            default               : return nil
            }
        default: return nil
        }
    }
}
