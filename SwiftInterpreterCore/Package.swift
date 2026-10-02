// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftInterpreterCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftInterpreterCore",
            targets: ["SwiftInterpreterCore"]
        )
    ],
    dependencies: [
        .package(path: "../Vendor/SwiftScript"),
        .package(
            url: "https://github.com/Cocoanetics/ShellKit.git",
            revision: "40c1b417e6c6318d2ca644d9a3062dc6befd0e31"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax",
            exact: "603.0.2"
        )
    ],
    targets: [
        .target(
            name: "SwiftInterpreterCore",
            dependencies: [
                .product(
                    name: "SwiftScriptInterpreter",
                    package: "SwiftScript"
                ),
                .product(
                    name: "SwiftScriptAST",
                    package: "SwiftScript"
                ),
                .product(
                    name: "ShellKit",
                    package: "ShellKit"
                ),
                .product(
                    name: "SwiftParser",
                    package: "swift-syntax"
                ),
                .product(
                    name: "SwiftSyntax",
                    package: "swift-syntax"
                )
            ]
        ),
        .testTarget(
            name: "SwiftInterpreterCoreTests",
            dependencies: ["SwiftInterpreterCore"]
        )
    ]
)
