// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Mixoto", platforms: [.macOS(.v15)], products: [.executable(name: "Mixoto", targets: ["Mixer"])], targets: [.executableTarget(name: "Mixer", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "MixerTests", dependencies: ["Mixer"], swiftSettings: [.swiftLanguageMode(.v5)])])
