//
//  MDBSQLiteConnection.swift
//  MIODBSQLite
//
//  Created by Javier Segura Perez on 25/07/2026.
//  Copyright © 2026 Javier Segura Perez. All rights reserved.
//

import Foundation
import MIODB

/// Connection factory for the SQLite backend. Subclasses the plain
/// `MDBConnection`: no credentials, no schemas. `database` (or the `to_db`
/// argument of `create`) is the database file path, or ":memory:".
open class MDBSQLiteConnection : MDBConnection
{
    open override func create ( _ to_db: String? = nil, identifier: String? = nil, label: String? = nil, delegate: MDBDelegate? = nil ) throws -> MIODB {
        let db = MIODBSQLite( connection: self )
        db.delegate = delegate
        if let id = identifier { db.identifier = id }
        if let lbl = label { db.label = lbl }
        try db.connect( to_db )
        return db
    }
}
