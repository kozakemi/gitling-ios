// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "SwiftTerm", platforms: [.iOS("18.0")],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"],
        resources: [.copy("Apple/Metal/Shaders.metal")])])
