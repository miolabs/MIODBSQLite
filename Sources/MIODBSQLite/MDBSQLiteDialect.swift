//
//  MDBSQLiteDialect.swift
//  MIODBSQLite
//
//  Created by Javier Segura Perez on 27/07/2026.
//  Copyright © 2026 Javier Segura Perez. All rights reserved.
//

import Foundation
import MIODB

/// SQLite rendering of MDBQuery. Replaces the old post-hoc string shims
/// (strip " FOR UPDATE", rewrite " ILIKE ") which could corrupt string
/// literals containing those sequences — the dialect adapts the constructs
/// where they are rendered, so literals are never touched.
open class MDBSQLiteDialect : MDBDialect
{
    public static let shared = MDBSQLiteDialect()

    /// SQLite writes lock the whole database file, so a row-lock hint is
    /// meaningless and dropping it preserves the semantics. This is the one
    /// unsupported construct that is dropped instead of throwing.
    open override func forUpdateClause ( ) throws -> String { return "" }

    /// SQLite has no decode(): a bytes value is the blob literal X'<hex>'.
    open override func renderValue ( _ v: MDBValue ) -> String {
        if case .bytes( let d ) = v.storage { return "X'" + MDBValue.hex_string( d ) + "'" }
        return super.renderValue( v )
    }

    open override func whereOperator ( _ op: WHERE_LINE_OPERATOR ) throws -> String {
        switch op {
        // Plain LIKE is case-insensitive for ASCII in SQLite, which matches
        // ILIKE semantics for ASCII text.
        case .ILIKE:          return "LIKE"
        // SQLite has no unaccent; diacritic folding degrades to plain LIKE
        // (accent-sensitive), mirroring how ILIKE already degrades for
        // non-ASCII case.
        case .ILIKE_DI:       return "LIKE"
        case .JSON_EXISTS_IN: throw MDBError.unsupported( "?| (JSON_EXISTS_IN)", "SQLite" )
        default:              return op.rawValue
        }
    }

    open override func foldDiacriticsField ( _ field: String ) throws -> String { return field }
    open override func foldDiacriticsValue ( _ value: String ) throws -> String { return value }

    open override func distinctOnClause ( _ q: MDBQuery ) throws -> String {
        let clause = try super.distinctOnClause( q )
        guard clause.isEmpty else { throw MDBError.unsupported( "DISTINCT ON", "SQLite" ) }
        return clause
    }

    open override func joinClause ( _ join: Join ) throws -> String {
        guard !( join is JoinJSON ) else { throw MDBError.unsupported( "JSON relation join (::jsonb ?)", "SQLite" ) }
        return try super.joinClause( join )
    }

    /// SQLite accepts UPDATE ... FROM (3.33+) but does not accept a column
    /// list on a table alias — a VALUES table exposes its columns as
    /// column1..columnN — so the `s` table renames them with a SELECT.
    open override func multiUpdate ( _ q: MDBQuery ) throws -> String {
        let sorted_values = q.sortedValues( q.multiValues.count > 0 ? q.multiValues[ 0 ] : [:] )
        if sorted_values.isEmpty { return "" }

        let renames = sorted_values.enumerated().map{ (i, col) in "column\(i+1) AS \"\(col.key)\"" }.joined( separator: ", " )
        return q.composeQuery( [ "UPDATE " + tableRef( q ) + " SET"
                               , q.multiUpdateValuesRaw( )
                               , "FROM (SELECT " + renames + " FROM (VALUES "
                               , multiValuesList( q, sorted_values )
                               , ")) AS s"
                               , try whereClause( q )
                               , try returningClause( q )
                               ] )
    }
}
