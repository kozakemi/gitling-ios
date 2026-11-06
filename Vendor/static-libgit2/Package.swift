// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "static-libgit2",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "static-libgit2", targets: ["Clibgit2", "LinkerConfigurator"]),
    ],
    targets: [
        .binaryTarget(name: "Clibgit2", path: "Clibgit2.xcframework"),
        .target(
            name: "LinkerConfigurator",
            path: "LinkerConfigurator",
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
