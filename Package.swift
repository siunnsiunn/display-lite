// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "display-lite",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DDCKit", targets: ["DDCKit"]),
        .executable(name: "ddcprobe", targets: ["ddcprobe"]),
        .executable(name: "DisplayLite", targets: ["DisplayLite"])
    ],
    targets: [
        .target(name: "DDCKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "ddcprobe", dependencies: ["DDCKit"]),
        .executableTarget(name: "DisplayLite", dependencies: ["DDCKit"],
                          linkerSettings: [.linkedFramework("AppKit")])
    ]
)
