// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WinlayCore", platforms: [.macOS(.v15)], products: [.library(name: "WinlayCore", targets: ["WinlayCore"])], targets: [
    .target(name: "WinlayCore", path: "Winlay/Core"),
    .testTarget(name: "WinlayCoreTests", dependencies: ["WinlayCore"], path: "WinlayTests")
])
