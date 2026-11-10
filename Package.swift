// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Mixoto",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Mixoto", targets: ["Mixer"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        // AVAudioEngine reports some errors as Objective-C exceptions, which Swift cannot catch.
        .target(name: "ObjCCatch"),
        .executableTarget(
            name: "Mixer",
            dependencies: ["ObjCCatch", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MixerTests", dependencies: ["Mixer"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
