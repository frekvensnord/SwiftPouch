// swift-tools-version: 6.3
import PackageDescription

// SwiftScript d298d01dc1aa34d68700f7d0e37ad26b52b36dfc, with the
// interpreter compatibility fixes kept in this repository. See LICENSE.
let package = Package(
    name: "SwiftScript",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftScriptAST", targets: ["SwiftScriptAST"]),
        .library(name: "SwiftScriptInterpreter", targets: ["SwiftScriptInterpreter"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2"),
        .package(url: "https://github.com/Cocoanetics/ShellKit.git",
                 revision: "40c1b417e6c6318d2ca644d9a3062dc6befd0e31")
    ],
    targets: [
        .target(name: "SwiftScriptAST", dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "SwiftOperators", package: "swift-syntax"),
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            .product(name: "SwiftParserDiagnostics", package: "swift-syntax")
        ], path: "Sources/SwiftScriptAST"),
        .target(name: "SwiftScriptInterpreter", dependencies: [
            "SwiftScriptAST",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "ShellKit", package: "ShellKit")
        ], path: "Sources/SwiftScriptInterpreter")
    ]
)
