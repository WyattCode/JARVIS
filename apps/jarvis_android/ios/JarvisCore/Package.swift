// swift-tools-version: 6.0
import PackageDescription

// The app's core in Swift (models, storage, network). It has no UI and no Flutter in it, so it builds and is tested on the
// Mac (`swift test`); the app target compiles the same sources.
let package = Package(
  name: "JarvisCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "JarvisCore", targets: ["JarvisCore"])],
  targets: [
    .target(name: "JarvisCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
