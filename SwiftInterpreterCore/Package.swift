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
        .package(
            url: "https://github.com/Cocoanetics/SwiftScript.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/Cocoanetics/ShellKit.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax",
            from: "603.0.0"
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
