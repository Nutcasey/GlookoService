// swift-tools-version:5.9
import PackageDescription

// GlookoKit is the LoopKit-free core (Glooko client, IBF encoder, history log), so it builds and tests on a Mac.
// The Loop plugin itself is built from GlookoService.xcodeproj inside LoopWorkspace.
let package = Package(
    name: "GlookoService",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [.library(name: "GlookoKit", targets: ["GlookoKit"])],
    targets: [
        .target(name: "GlookoKit", path: "GlookoKit"),
        .testTarget(name: "GlookoKitTests", dependencies: ["GlookoKit"], path: "Tests/GlookoKitTests"),
    ]
)
