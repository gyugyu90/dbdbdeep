// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "dbdbdeep",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "dbdbdeep", targets: ["DBDeepApp"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "DBDeepCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "DBDeepApp", dependencies: ["DBDeepCore"]),
        .testTarget(name: "DBDeepCoreTests", dependencies: ["DBDeepCore"])
    ]
)
