// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MIODBSQLite",
    platforms: [.macOS(.v12)],
    products: [
        .library( name: "MIODBSQLite", targets: ["MIODBSQLite"]),
    ],
    dependencies: [
        .package(url: "https://github.com/miolabs/MIODB.git", branch: "master" ),
        .package(url: "https://github.com/miolabs/MIOCore.git", from: "2.0.0" )
    ],
    targets: [
        // On Apple platforms the SDK ships <sqlite3.h> and libsqlite3.tbd, so
        // this resolves without any package manager. On Linux install
        // libsqlite3-dev.
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"])
            ]
        ),
        .target(
            name: "MIODBSQLite",
            dependencies: [
                .product(name: "MIODB", package: "MIODB"),
                .product(name: "MIOCore", package: "MIOCore"),
                .product(name: "MIOCoreLogger", package: "MIOCore"),
                "CSQLite",
            ]),
        .testTarget(
            name: "MIODBSQLiteTests",
            dependencies: ["MIODBSQLite"]),
        // Runnable tour of the API: `swift run Example`
        .executableTarget(
            name: "Example",
            dependencies: ["MIODBSQLite"]),
    ]
)
