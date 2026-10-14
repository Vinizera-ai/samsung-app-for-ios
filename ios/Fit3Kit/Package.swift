// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fit3Kit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Fit3Kit", targets: ["Fit3Kit"])],
    targets: [
        .target(name: "Fit3Kit"),
        .testTarget(name: "Fit3KitTests", dependencies: ["Fit3Kit"]),
    ]
)
