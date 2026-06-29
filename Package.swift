// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FolderBase",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "FolderBase", targets: ["FolderBase"])
    ],
    targets: [
        .executableTarget(
            name: "FolderBase",
            path: "FolderBase",
            exclude: ["Resources"]
        )
    ]
)
